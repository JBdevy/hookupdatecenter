#!/usr/bin/env python3
"""Convert CatLive's licensed HTDemucs checkpoint to an iOS 16 Core ML program.

Run with the existing StemSeparationRuntime Python and coremltools on PYTHONPATH.
Separate stages release Torch/graph memory between tracing, conversion and testing.
The vDSP worker implements the identical STFT/ISTFT; this graph preserves both
trained branches and their normalization. No estimated or substitute stems.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import time

os.environ.setdefault("OMP_NUM_THREADS", "2")
os.environ.setdefault("VECLIB_MAXIMUM_THREADS", "2")
parser = argparse.ArgumentParser()
parser.add_argument("--stage", choices=["trace", "convert", "validate"], required=True)
parser.add_argument("--checkpoint", type=Path, required=True)
parser.add_argument("--work", type=Path, default=Path("build/CatStemCoreML"))
parser.add_argument("--precision", choices=["fp16", "fp32"], default="fp16")
args = parser.parse_args()
args.work.mkdir(parents=True, exist_ok=True)

import numpy as np
import torch

torch.set_num_threads(2)
torch.set_num_interop_threads(2)
if hasattr(torch.backends, "mha"):
    torch.backends.mha.set_fastpath_enabled(False)

def exportable_attention(self, query, key, value, key_padding_mask=None, need_weights=True,
                         attn_mask=None, average_attn_weights=True, is_causal=False):
    # Torch 2.2's inference-only fused attention has no Core ML converter.
    # Use its own equivalent functional implementation with the same weights.
    batched = query.dim() == 3
    if self.batch_first and batched:
        query, key, value = (tensor.transpose(0, 1) for tensor in (query, key, value))
    output, weights = torch.nn.functional.multi_head_attention_forward(
        query, key, value, self.embed_dim, self.num_heads, self.in_proj_weight, self.in_proj_bias,
        self.bias_k, self.bias_v, self.add_zero_attn, self.dropout,
        self.out_proj.weight, self.out_proj.bias, training=self.training,
        key_padding_mask=key_padding_mask, need_weights=need_weights, attn_mask=attn_mask,
        use_separate_proj_weight=not self._qkv_same_embed_dim,
        q_proj_weight=self.q_proj_weight, k_proj_weight=self.k_proj_weight, v_proj_weight=self.v_proj_weight,
        average_attn_weights=average_attn_weights, is_causal=is_causal)
    return (output.transpose(0, 1) if self.batch_first and batched else output), weights

original_attention = torch.nn.MultiheadAttention.forward
torch.nn.MultiheadAttention.forward = exportable_attention

class SpectralTemporalNetwork(torch.nn.Module):
    """Demucs HTDemucs.forward between _magnitude and _mask/_ispec.

    Architecture follows Meta's MIT-licensed demucs/htdemucs.py. Registered
    child modules keep the checkpoint weights and exact trained operations.
    """
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, audio, spectrum):
        m = self.model
        x = spectrum
        B, C, Fq, T = x.shape
        mean = x.mean(dim=(1, 2, 3), keepdim=True)
        std = x.std(dim=(1, 2, 3), keepdim=True)
        x = (x - mean) / (1e-5 + std)
        meant = audio.mean(dim=(1, 2), keepdim=True)
        stdt = audio.std(dim=(1, 2), keepdim=True)
        xt = (audio - meant) / (1e-5 + stdt)
        saved, saved_t, lengths, lengths_t = [], [], [], []
        for index, encode in enumerate(m.encoder):
            lengths.append(x.shape[-1])
            inject = None
            if index < len(m.tencoder):
                lengths_t.append(xt.shape[-1])
                tenc = m.tencoder[index]
                xt = tenc(xt)
                if not tenc.empty:
                    saved_t.append(xt)
                else:
                    inject = xt
            x = encode(x, inject)
            if index == 0 and m.freq_emb is not None:
                frequencies = torch.arange(x.shape[-2], device=x.device)
                embedding = m.freq_emb(frequencies).t()[None, :, :, None].expand_as(x)
                x = x + m.freq_emb_scale * embedding
            saved.append(x)
        if m.crosstransformer:
            if m.bottom_channels:
                b, c, f, t = x.shape
                x = m.channel_upsampler(x.reshape(b, c, f * t)).reshape(b, -1, f, t)
                xt = m.channel_upsampler_t(xt)
            x, xt = m.crosstransformer(x, xt)
            if m.bottom_channels:
                b, c, f, t = x.shape
                x = m.channel_downsampler(x.reshape(b, c, f * t)).reshape(b, -1, f, t)
                xt = m.channel_downsampler_t(xt)
        for index, decode in enumerate(m.decoder):
            x, pre = decode(x, saved.pop(), lengths.pop())
            offset = m.depth - len(m.tdecoder)
            if index >= offset:
                decoder = m.tdecoder[index - offset]
                length_t = lengths_t.pop()
                if decoder.empty:
                    xt, _ = decoder(pre[:, :, 0], None, length_t)
                else:
                    xt, _ = decoder(xt, saved_t.pop(), length_t)
        spectral = x.reshape(B, len(m.sources), -1, Fq, T) * std[:, None] + mean[:, None]
        temporal = xt.reshape(B, len(m.sources), -1, audio.shape[-1]) * stdt[:, None] + meant[:, None]
        return spectral, temporal

name = "CatStemHTDemucs6"
traced_path = args.work / (name + ".pt")
package_path = args.work / (name + ".mlpackage")
if args.stage == "trace":
    from demucs.states import load_model
    print("Loading checkpoint", flush=True)
    digest = hashlib.sha256(args.checkpoint.read_bytes()).hexdigest()
    assert digest == "34c22ccb381c6f9fdbf324f04e1e2fe21aaaf293f5ded163a162697ff9a02ddd", "Unexpected model checkpoint"
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    model = load_model(checkpoint).eval()
    model.use_train_segment = False
    model.segment = 1.0
    assert model.cac and model.samplerate == 44100 and model.nfft == 4096
    assert model.sources == ["drums", "bass", "other", "vocals", "guitar", "piano"], model.sources
    network = SpectralTemporalNetwork(model).eval()
    t = torch.arange(44100, dtype=torch.float32) / 44100
    generator = torch.Generator().manual_seed(7357)
    fixtures = {
        "silence": torch.zeros(1, 2, 44100),
        "noise": 0.1 * torch.randn(1, 2, 44100, generator=generator),
        "tones": torch.stack((0.3 * torch.sin(2 * torch.pi * 220 * t) + 0.2 * torch.sin(2 * torch.pi * 311 * t),
                               0.2 * torch.sin(2 * torch.pi * 440 * t) + 0.15 * torch.sin(2 * torch.pi * 97 * t)))[None],
    }
    with torch.no_grad():
        for key, audio in fixtures.items():
            spectrum = model._magnitude(model._spec(audio))
            assert tuple(spectrum.shape) == (1, 4, 2048, 44), spectrum.shape
            spectral, temporal = network(audio, spectrum)
            reconstructed = model._ispec(model._mask(model._spec(audio), spectral), 44100) + temporal
            torch.nn.MultiheadAttention.forward = original_attention
            reference = model(audio)
            torch.nn.MultiheadAttention.forward = exportable_attention
            assert torch.allclose(reconstructed, reference, atol=1e-6, rtol=1e-5), float((reconstructed-reference).abs().max())
            np.savez(args.work / (key + ".npz"), audio=audio.numpy(), spectrum=spectrum.numpy(),
                     spectrum_out=spectral.numpy(), audio_out=temporal.numpy(), pcm=reference.numpy())
            print("Fixture", key, "validated", flush=True)
        print("Tracing", flush=True)
        audio = fixtures["tones"]
        traced = torch.jit.trace(network, (audio, model._magnitude(model._spec(audio))), check_trace=False)
        traced.save(str(traced_path))
    metadata = {"checkpoint": args.checkpoint.stem, "sha256": hashlib.sha256(args.checkpoint.read_bytes()).hexdigest(),
                "sources": model.sources, "sample_rate": 44100, "window_frames": 44100, "fft": 4096, "hop": 1024,
                "spectral_frames": 44, "torch": torch.__version__, "precision": args.precision}
    (args.work / "metadata.json").write_text(json.dumps(metadata, indent=2))
    print("Trace saved", traced_path, flush=True)
elif args.stage == "convert":
    import coremltools as ct
    traced = torch.jit.load(str(traced_path)).eval()
    metadata = json.loads((args.work / "metadata.json").read_text())
    print("Converting", ct.__version__, args.precision, flush=True)
    converted = ct.convert(traced, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS16,
        inputs=[ct.TensorType(name="audio", shape=(1, 2, 44100), dtype=np.float32),
                ct.TensorType(name="spectrum", shape=(1, 4, 2048, 44), dtype=np.float32)],
        outputs=[ct.TensorType(name="spectrum_out", dtype=np.float32), ct.TensorType(name="audio_out", dtype=np.float32)],
        compute_precision=ct.precision.FLOAT16 if args.precision == "fp16" else ct.precision.FLOAT32,
        skip_model_load=True)
    converted.short_description = "CatLive CatStem: original HTDemucs6 spectral and temporal separation network"
    converted.user_defined_metadata["catlive.source_checkpoint"] = metadata["checkpoint"]
    converted.user_defined_metadata["catlive.source_sha256"] = metadata["sha256"]
    converted.user_defined_metadata["catlive.sources"] = ",".join(metadata["sources"])
    converted.user_defined_metadata["catlive.window_frames"] = "44100"
    converted.save(str(package_path))
    print("Package saved", package_path, flush=True)
else:
    import coremltools as ct
    print("Loading CoreML for numerical validation", flush=True)
    model = ct.models.MLModel(str(package_path), compute_units=ct.ComputeUnit.CPU_AND_GPU)
    report = {}
    for key in ["silence", "noise", "tones"]:
        fixture = np.load(args.work / (key + ".npz"))
        started = time.monotonic()
        output = model.predict({"audio": fixture["audio"], "spectrum": fixture["spectrum"]})
        errors = {}
        for name in ["spectrum_out", "audio_out"]:
            predicted = output[name].astype(np.float32)
            expected = fixture[name]
            assert predicted.shape == expected.shape, (name, predicted.shape, expected.shape)
            assert np.isfinite(predicted).all(), name
            error = predicted - expected
            rms = float(np.sqrt(np.mean(error.astype(np.float64) ** 2)))
            reference_rms = float(np.sqrt(np.mean(expected.astype(np.float64) ** 2)))
            maximum = float(np.abs(error).max())
            errors[name] = {"maximum_absolute": maximum, "rms": rms, "reference_rms": reference_rms,
                            "relative_rms": rms / max(1e-8, reference_rms)}
            assert rms <= max(2e-5, reference_rms * 0.02), (key, name, errors[name])
        from demucs.spec import ispectro
        spec = torch.from_numpy(output["spectrum_out"].astype(np.float32))
        complex_spec = torch.view_as_complex(spec.reshape(1, 6, 2, 2, 2048, 44).permute(0, 1, 2, 4, 5, 3).contiguous())
        complex_spec = torch.nn.functional.pad(complex_spec, (0, 0, 0, 1))
        complex_spec = torch.nn.functional.pad(complex_spec, (2, 2))
        pcm = ispectro(complex_spec, 1024, length=44*1024+3072)[..., 1536:1536+44100].numpy() + output["audio_out"]
        pcm_error = pcm.astype(np.float64) - fixture["pcm"]
        pcm_rms = float(np.sqrt(np.mean(pcm_error**2)))
        reference_rms = float(np.sqrt(np.mean(fixture["pcm"].astype(np.float64)**2)))
        errors["pcm"] = {"rms": pcm_rms, "reference_rms": reference_rms, "relative_rms": pcm_rms/max(1e-8, reference_rms), "maximum_absolute": float(np.abs(pcm_error).max())}
        assert pcm_rms <= max(2e-5, reference_rms*0.02), (key, errors["pcm"])
        report[key] = {"seconds": time.monotonic() - started, "errors": errors}
        print(key, json.dumps(report[key]), flush=True)
    (args.work / "validation.json").write_text(json.dumps(report, indent=2))
    print("Core ML numerical validation PASS", flush=True)
