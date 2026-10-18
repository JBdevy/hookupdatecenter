#!/usr/bin/env python3
"""FP32 HTDemucs6 inference with a GPU neural graph and exact CPU transforms.

The network forward is adapted from demucs/htdemucs.py, Copyright Meta Platforms,
MIT license (bundled Demucs-LICENSE.txt). Model weights, source mapping and signal
normalization are unchanged. Conversion occurs during packaging, never playback.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import sys
import tempfile

os.environ.setdefault('OPENVINO_TELEMETRY_OPT_OUT', '1')
import numpy as np
import torch
import openvino as ov

SOURCE_SHA = '34c22ccb381c6f9fdbf324f04e1e2fe21aaaf293f5ded163a162697ff9a02ddd'
SOURCES = ['drums', 'bass', 'other', 'vocals', 'guitar', 'piano']
CONTEXT = RATE = 44100
FORMAT_VERSION = 1
MODEL_FILE = 'htdemucs6-openvino.xml'
MANIFEST_FILE = 'htdemucs6-openvino.json'

def digest(path):
    with Path(path).open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()

class NetworkCore(torch.nn.Module):
    def __init__(self, model):
        super().__init__(); self.model=model
    def forward(self,mix,mag):
        m=self.model
        batch,channels,frequencies,frames=mag.shape
        mean=mag.mean(dim=(1,2,3),keepdim=True)
        std=mag.std(dim=(1,2,3),keepdim=True)
        x=(mag-mean)/(1e-5+std)
        meant=mix.mean(dim=(1,2),keepdim=True)
        stdt=mix.std(dim=(1,2),keepdim=True)
        xt=(mix-meant)/(1e-5+stdt)
        saved=[];saved_t=[];lengths=[];lengths_t=[]
        for index,encode in enumerate(m.encoder):
            lengths.append(x.shape[-1]);inject=None
            if index<len(m.tencoder):
                lengths_t.append(xt.shape[-1]);tenc=m.tencoder[index];xt=tenc(xt)
                if not tenc.empty: saved_t.append(xt)
                else: inject=xt
            x=encode(x,inject)
            if index==0 and m.freq_emb is not None:
                frequency_indices=torch.arange(x.shape[-2],device=x.device)
                embedding=m.freq_emb(frequency_indices).t()[None,:,:,None].expand_as(x)
                x=x+m.freq_emb_scale*embedding
            saved.append(x)
        if m.crosstransformer:
            if m.bottom_channels:
                b,c,f,t=x.shape
                x=m.channel_upsampler(x.reshape(b,c,f*t)).reshape(b,-1,f,t)
                xt=m.channel_upsampler_t(xt)
            x,xt=m.crosstransformer(x,xt)
            if m.bottom_channels:
                b,c,f,t=x.shape
                x=m.channel_downsampler(x.reshape(b,c,f*t)).reshape(b,-1,f,t)
                xt=m.channel_downsampler_t(xt)
        for index,decode in enumerate(m.decoder):
            x,pre=decode(x,saved.pop(),lengths.pop())
            offset=m.depth-len(m.tdecoder)
            if index>=offset:
                tdec=m.tdecoder[index-offset];length_t=lengths_t.pop()
                if tdec.empty: xt,_=tdec(pre[:,:,0],None,length_t)
                else: xt,_=tdec(xt,saved_t.pop(),length_t)
        sources=len(m.sources)
        x=x.view(batch,sources,-1,frequencies,frames)
        x=x*std[:,None]+mean[:,None]
        xt=xt.view(batch,sources,-1,mix.shape[-1])
        xt=xt*stdt[:,None]+meant[:,None]
        return x,xt


class SpectralTransform:
    """Demucs' exact normalized STFT/ISTFT, without loading network weights."""
    def __init__(self, nfft, hop_length):
        if nfft != 4096 or hop_length != nfft // 4:
            raise ValueError('Unexpected HTDemucs6 spectral configuration')
        self.nfft, self.hop_length = nfft, hop_length
        self.window = torch.hann_window(nfft)

    def encode(self, pcm):
        batch, channels, length = pcm.shape
        frames = int(math.ceil(length / self.hop_length))
        pad = self.hop_length // 2 * 3
        padded = torch.nn.functional.pad(pcm, (pad, pad + frames*self.hop_length-length), mode='reflect')
        spectrum = torch.stft(padded.reshape(-1,padded.shape[-1]), self.nfft, self.hop_length,
            window=self.window, win_length=self.nfft, normalized=True, center=True,
            return_complex=True, pad_mode='reflect')
        spectrum = spectrum[:,:-1,2:2+frames].reshape(batch,channels,self.nfft//2,frames)
        return torch.view_as_real(spectrum).permute(0,1,4,2,3).reshape(batch,channels*2,self.nfft//2,frames)

    def decode(self, frequency, temporal, length):
        batch, sources, channels, frequencies, frames = frequency.shape
        spectrum = torch.view_as_complex(frequency.view(batch,sources,-1,2,frequencies,frames)
                                        .permute(0,1,2,4,5,3).contiguous())
        spectrum = torch.nn.functional.pad(spectrum, (0,0,0,1))
        spectrum = torch.nn.functional.pad(spectrum, (2,2))
        pad = self.hop_length // 2 * 3
        padded_length = self.hop_length * int(math.ceil(length/self.hop_length)) + 2*pad
        pcm = torch.istft(spectrum.reshape(-1,spectrum.shape[-2],spectrum.shape[-1]),
            self.nfft,self.hop_length,window=self.window,win_length=self.nfft,
            normalized=True,length=padded_length,center=True)
        pcm = pcm.view(batch,sources,channels//2,padded_length)[...,pad:pad+length]
        return pcm + temporal


def configure_torch():
    torch.set_num_threads(max(1,min(8,os.cpu_count() or 1)))
    if torch.get_num_interop_threads() != 1:
        torch.set_num_interop_threads(1)


def verified_manifest(directory):
    directory = Path(directory)
    manifest = json.loads((directory/MANIFEST_FILE).read_text(encoding='utf-8'))
    if (manifest.get('formatVersion') != FORMAT_VERSION or manifest.get('sourceCheckpointSHA') != SOURCE_SHA
            or manifest.get('contextFrames') != CONTEXT or manifest.get('sampleRate') != RATE
            or manifest.get('sources') != SOURCES or manifest.get('precision') != 'f32'
            or manifest.get('nfft') != 4096 or manifest.get('hopLength') != 1024):
        raise ValueError('The CatStem OpenVINO model has an incompatible identity or configuration')
    for name in (MODEL_FILE,Path(MODEL_FILE).with_suffix('.bin').name):
        if digest(directory/name) != manifest.get('files',{}).get(name):
            raise ValueError('CatStem OpenVINO model SHA256 mismatch: '+name)
    return manifest


def convert_model(model_path, output_directory):
    """Build a static FP32 IR and prove it matches the pinned eager checkpoint."""
    model_path, directory = Path(model_path), Path(output_directory)
    if digest(model_path) != SOURCE_SHA:
        raise ValueError('CatStem source checkpoint SHA256 mismatch')
    configure_torch()
    from demucs.states import load_model
    original = load_model(model_path).eval()
    if list(original.sources) != SOURCES or original.samplerate != RATE or not original.cac:
        raise ValueError('Unexpected CatStem source/sample-rate/model contract')
    original.segment = CONTEXT/RATE
    network = NetworkCore(original).eval()
    spectral = SpectralTransform(original.nfft, original.hop_length)
    generator = np.random.default_rng(19)
    fixtures = [generator.normal(0,.03,(1,2,CONTEXT)).astype(np.float32)]
    time = np.arange(CONTEXT,dtype=np.float32)/RATE
    harmonic = np.stack((.1*np.sin(time*440*2*np.pi), .07*np.sin(time*660*2*np.pi)))[None]
    harmonic[:,:,::4096] += .2
    fixtures.append(harmonic.astype(np.float32))
    fixtures.append(generator.normal(0,.0001,(1,2,CONTEXT)).astype(np.float32))
    example = torch.from_numpy(fixtures[0])
    with torch.inference_mode():
        magnitude = spectral.encode(example)
        expected_magnitude = original._magnitude(original._spec(example))
        if not torch.equal(magnitude,expected_magnitude):
            raise RuntimeError('CatStem CPU spectral encoding differs from the original')
        frequency,temporal = network(example,magnitude)
        reconstructed = spectral.decode(frequency,temporal,CONTEXT)
        reference = original(example)
        split_error = float((reconstructed-reference).abs().max())
        if split_error > 1e-6:
            raise RuntimeError('CatStem split graph differs from the original')
        # Fixed input size is part of the signed runtime contract. PyTorch 2.2
        # changes its MHA implementation during a second trace pass; numerical
        # validation against independent eager fixtures follows conversion.
        traced = torch.jit.trace(network,(example,magnitude),check_trace=False,strict=False)
    converted = ov.convert_model(traced,input=[list(example.shape),list(magnitude.shape)])
    core = ov.Core()
    compiled = core.compile_model(converted,'CPU',{'PERFORMANCE_HINT':'LATENCY',
        'INFERENCE_PRECISION_HINT':'f32','INFERENCE_NUM_THREADS':max(1,min(8,os.cpu_count() or 1))})
    request = compiled.create_infer_request()
    checks=[]
    for fixture in fixtures:
        pcm = torch.from_numpy(fixture)
        with torch.inference_mode():
            reference = original(pcm).numpy()
            magnitude = spectral.encode(pcm)
            values = request.infer({0:fixture,1:magnitude.numpy()})
            frequency = torch.from_numpy(values[compiled.output(0)].copy())
            temporal = torch.from_numpy(values[compiled.output(1)].copy())
            predicted = spectral.decode(frequency,temporal,CONTEXT).numpy()
        error = predicted-reference
        maximum = float(np.abs(error).max())
        relative = float(np.sqrt(np.mean(error**2))/max(1e-12,np.sqrt(np.mean(reference**2))))
        if not np.isfinite(predicted).all() or maximum > 2e-5 or relative > .001:
            raise RuntimeError('CatStem OpenVINO conversion failed FP32 output validation')
        checks.append({'maximumAbsoluteError':maximum,'relativeRMSError':relative})
    directory.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='catstem-ir-',dir=directory) as temporary:
        temporary = Path(temporary)
        ov.save_model(converted,str(temporary/MODEL_FILE),compress_to_fp16=False)
        files={name:digest(temporary/name) for name in (MODEL_FILE,Path(MODEL_FILE).with_suffix('.bin').name)}
        manifest={'formatVersion':FORMAT_VERSION,'sourceCheckpointSHA':SOURCE_SHA,
                  'sampleRate':RATE,'contextFrames':CONTEXT,'sources':SOURCES,'precision':'f32',
                  'nfft':original.nfft,'hopLength':original.hop_length,'openvino':ov.__version__,
                  'torch':torch.__version__,'files':files,'validation':checks,'splitGraphMaximumError':split_error}
        for name in files: (temporary/name).replace(directory/name)
        (temporary/MANIFEST_FILE).write_text(json.dumps(manifest,indent=2),encoding='utf-8')
        (temporary/MANIFEST_FILE).replace(directory/MANIFEST_FILE)
    return manifest


class OpenVINOBackend:
    def __init__(self, protocol, model_path, device='auto', crossfade_frames=1024):
        if not 0 <= crossfade_frames <= min(protocol.RIGHT,protocol.HOP):
            raise ValueError('Crossfade must fit within captured right context')
        if protocol.CONTEXT != CONTEXT or protocol.RATE != RATE or list(protocol.SOURCES) != SOURCES:
            raise ValueError('Unexpected CatStem stream contract')
        model_path = Path(model_path)
        if digest(model_path) != SOURCE_SHA:
            raise ValueError('CatStem source checkpoint SHA256 mismatch')
        manifest = verified_manifest(model_path.parent)
        configure_torch()
        self.protocol, self.np, self.torch = protocol, np, torch
        self.spectral = SpectralTransform(manifest['nfft'],manifest['hopLength'])
        core = ov.Core()
        self.device = ('GPU' if 'GPU' in core.available_devices else 'CPU') if device == 'auto' else device.upper()
        if self.device not in ('CPU','GPU'):
            raise ValueError('OpenVINO CatStem requires CPU or Intel GPU')
        local = Path(os.environ.get('LOCALAPPDATA',str(Path.home()/'AppData/Local')))
        cache = local/'Hook Developer/CatLive/Cache/CatStem'/manifest['files'][MODEL_FILE]
        cache.mkdir(parents=True,exist_ok=True)
        options={'PERFORMANCE_HINT':'LATENCY','INFERENCE_PRECISION_HINT':'f32','CACHE_DIR':str(cache)}
        if self.device == 'CPU': options['INFERENCE_NUM_THREADS']=max(1,min(8,os.cpu_count() or 1))
        self.compiled=core.compile_model(str(model_path.parent/MODEL_FILE),self.device,options)
        self.request=self.compiled.create_infer_request()
        self.crossfade=crossfade_frames
        self.context=np.zeros((protocol.CHANNELS,protocol.CONTEXT),dtype=np.float32)
        self.previous_tail=None
        self.skipped_silent_blocks=0
        self.fade=np.linspace(0,1,crossfade_frames,dtype=np.float32)[None,None,:] if crossfade_frames else None
        self.model_sha=SOURCE_SHA

    def reset(self): return self.protocol.StreamingBackend.reset(self)
    def warmup(self): return self.protocol.StreamingBackend.warmup(self)
    def process(self,payload): return self.protocol.StreamingBackend.process(self,payload)

    def estimate(self):
        with torch.inference_mode():
            pcm=torch.from_numpy(self.context[None].copy())
            magnitude=self.spectral.encode(pcm)
            values=self.request.infer({0:pcm.numpy(),1:magnitude.numpy()})
            frequency=torch.from_numpy(values[self.compiled.output(0)].copy())
            temporal=torch.from_numpy(values[self.compiled.output(1)].copy())
            start=self.protocol.CONTEXT-self.protocol.RIGHT-self.protocol.HOP
            end=self.protocol.CONTEXT-self.protocol.RIGHT+self.crossfade
            predicted=self.spectral.decode(frequency,temporal,self.protocol.CONTEXT)[0,:,:,start:end]
            output=torch.stack([predicted[3],predicted[0],predicted[1],predicted[4],predicted[2]+predicted[5]]).numpy().copy(order='C')
        if output.shape != (self.protocol.STEMS,self.protocol.CHANNELS,self.protocol.HOP+self.crossfade) or not np.isfinite(output).all():
            raise ValueError('Nonfinite or malformed CatStem output')
        return output


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--verify',action='store_true')
    args=parser.parse_args()
    if args.verify:
        if digest(args.model) != SOURCE_SHA:
            raise ValueError('CatStem source checkpoint SHA256 mismatch')
        result=verified_manifest(args.output)
    else:
        result=convert_model(args.model,args.output)
    print(json.dumps(result,allow_nan=False))
