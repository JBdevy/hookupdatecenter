"""CatStemSeparation 5 offline worker. Runs only while separating an item.
Demucs HTDemucs6 (MIT); Vocal/Drum/Bass/Guitar/Other, with piano in Other.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import time

MODEL_HASH = '34c22ccb381c6f9fdbf324f04e1e2fe21aaaf293f5ded163a162697ff9a02ddd'
OUTPUTS = ('Vocal', 'Drum', 'Bass', 'Guitar', 'Other')


def accelerated_model(model_path, requested, status):
    """Use only the bundled, hash-verified full-context Windows graph."""
    if sys.platform != 'win32' or requested == 'cpu':
        return None
    helper = Path(__file__).with_name('offline_openvino.py')
    if not helper.is_file():
        return None
    try:
        spec = importlib.util.spec_from_file_location('catstem_offline_openvino', helper)
        backend = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(backend)
        available = backend.ov.Core().available_devices
        devices = ['GPU', 'CPU'] if 'GPU' in available else ['CPU']
        for device in devices:
            try:
                status(0, 'Preparando a aceleração da separação…')
                model = backend.OfflineOpenVINOModel(model_path, device=device)
                return model
            except Exception as error:
                print(json.dumps(dict(event='accelerator_fallback', device=device, message=str(error)[:600])), file=sys.stderr, flush=True)
    except Exception as error:
        print(json.dumps(dict(event='accelerator_unavailable', message=str(error)[:600])), file=sys.stderr, flush=True)
    return None


def separate(args):
    # Imports/model loading stay in this short-lived process, never CatLive's UI/audio thread.
    def status(fraction, message):
        target = Path(args.output) / 'progress.json'
        temporary = target.with_suffix('.tmp')
        temporary.write_text(json.dumps(dict(fraction=fraction, message=message)), encoding='utf-8')
        temporary.replace(target)

    status(0, 'Carregando o modelo…')
    import numpy as np
    import soundfile as sf
    import torch
    from demucs.states import load_model
    from demucs import apply
    if hashlib.sha256(Path(args.model).read_bytes()).hexdigest() != MODEL_HASH:
        raise ValueError('O modelo de separação está incompleto ou corrompido.')
    # Offline Windows inference benefits from more than four CPU workers.
    # Keep two logical processors available to the UI/audio and cap at eight:
    # additional workers on hybrid CPUs can cost more in synchronization.
    cores = os.cpu_count() or 2
    threads = max(1, min(8, cores - 2)) if sys.platform == 'win32' else max(1, min(4, cores // 2))
    torch.set_num_threads(threads)
    torch.set_num_interop_threads(1)
    torch.manual_seed(0)
    model = accelerated_model(Path(args.model), args.device, status)
    backend_name = 'openvino-' + model.device_name.lower() if model is not None else 'torch'
    if model is None:
        torch.set_num_threads(threads)
        model = load_model(Path(args.model)).eval()
    audio, rate = sf.read(args.input, dtype='float32', always_2d=True)
    if rate != model.samplerate or audio.shape[1] != 2 or not len(audio):
        raise ValueError('A entrada deve ser estéreo, 44.1 kHz, com áudio.')
    if not np.isfinite(audio).all():
        raise ValueError('O áudio contém amostras inválidas.')
    mix = torch.from_numpy(audio.T.copy())
    reference = mix.mean(0)
    mean, scale = reference.mean(), reference.std(unbiased=False)
    device = 'mps' if backend_name == 'torch' and torch.backends.mps.is_available() and args.device != 'cpu' else 'cpu'
    # Progress follows completed inference chunks, not an estimated timer.
    def progress_iterator(iterable, **kwargs):
        total = len(iterable)
        started = time.monotonic()
        for index, entry in enumerate(iterable):
            message = 'Separando os instrumentos… ' + str(index + 1) + '/' + str(total)
            if index:
                remaining = round((time.monotonic() - started) / index * (total - index))
                minutes, seconds = divmod(remaining, 60)
                message += '\nRestante estimado: ' + str(minutes) + ' min ' + str(seconds).zfill(2) + ' s'
            status(0.05 + 0.85 * index / max(1, total), message)
            yield entry
    apply.tqdm.tqdm = progress_iterator
    if float(scale) < 1e-8:
        # Silence/DC needs no inference. Preserve it in Other, without multiplying DC.
        result = torch.zeros((len(model.sources), 2, len(audio)))
        result[model.sources.index('other')] = mix
    else:
        def infer():
            with torch.inference_mode():
                return apply.apply_model(model, ((mix - mean) / scale)[None], device=device,
                                         shifts=0, split=True, overlap=0.25, progress=True,
                                         num_workers=0)[0].cpu()
        retry_on_cpu = False
        try:
            result = infer()
        except Exception as error:
            if backend_name == 'torch':
                raise
            # An unavailable/lost accelerator must not strand the operation.
            # No output files are published until a complete prediction succeeds.
            print(json.dumps(dict(event='inference_fallback', backend=backend_name, message=str(error)[:600])), file=sys.stderr, flush=True)
            status(0, 'Continuando a separação pelo processador…')
            retry_on_cpu = True
        if retry_on_cpu:
            # Leave the exception handler before loading another model: its
            # traceback retains the failed graph and inference buffers.
            del model
            import gc
            gc.collect()
            torch.set_num_threads(threads)
            model = load_model(Path(args.model)).eval()
            device, backend_name = 'cpu', 'torch'
            result = infer()
        # Avoid two additional full-song, six-source tensors on 8-GB systems.
        with torch.inference_mode():
            result.mul_(scale).add_(mean / len(model.sources))
    indices = {name: index for index, name in enumerate(model.sources)}
    stems = [result[indices[name]] for name in ('vocals', 'drums', 'bass', 'guitar')]
    # Match the realtime/native five-source mixer: keep named estimates and
    # preserve all residual content (including piano) in Other.
    with torch.inference_mode():
        residual = mix.clone()
        for stem in stems:
            residual.sub_(stem)
    stems.append(residual)
    for index, (name, stem) in enumerate(zip(OUTPUTS, stems)):
        samples = stem.T.contiguous().numpy()
        if samples.shape != audio.shape or not np.isfinite(samples).all():
            raise ValueError('O modelo retornou áudio inválido.')
        status(0.90 + index * 0.02, 'Salvando ' + name + '…')
        # Float WAV preserves headroom: no separate normalization or clipping of stems.
        destination = Path(args.output) / (name + '.wav')
        temp = destination.with_suffix('.partial')
        sf.write(temp, samples, rate, format='WAV', subtype='FLOAT')
        temp.replace(destination)
    status(1, 'Separação concluída')
    print(json.dumps(dict(sources=list(OUTPUTS), sampleRate=rate, frames=len(audio), device=device, backend=backend_name)), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--model', required=True)
    parser.add_argument('--device', choices=['auto', 'cpu'], default='auto')
    args = parser.parse_args()
    try:
        separate(args)
    except Exception as error:
        import traceback
        traceback.print_exc()
        (Path(args.output) / 'error.txt').write_text(str(error), encoding='utf-8')
        sys.exit(1)
