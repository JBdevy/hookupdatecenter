"""CatStemSeparation 5 offline worker. Runs only while separating an item.
Demucs HTDemucs6 (MIT); Vocal/Drum/Bass/Guitar/Other, with piano in Other.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys

MODEL_HASH = '34c22ccb381c6f9fdbf324f04e1e2fe21aaaf293f5ded163a162697ff9a02ddd'
OUTPUTS = ('Vocal', 'Drum', 'Bass', 'Guitar', 'Other')


def separate(args):
    # Imports/model loading stay in this short-lived process, never CatLive's UI/audio thread.
    def status(fraction, message):
        target = Path(args.output) / 'progress.json'
        temporary = target.with_suffix('.tmp')
        temporary.write_text(json.dumps(dict(fraction=fraction, message=message)))
        temporary.replace(target)

    status(0, 'Carregando o modelo…')
    import numpy as np
    import soundfile as sf
    import torch
    from demucs.states import load_model
    from demucs import apply
    if hashlib.sha256(Path(args.model).read_bytes()).hexdigest() != MODEL_HASH:
        raise ValueError('O modelo de separação está incompleto ou corrompido.')
    torch.set_num_threads(max(1, min(4, (os.cpu_count() or 2) // 2)))
    torch.set_num_interop_threads(1)
    torch.manual_seed(0)
    model = load_model(Path(args.model)).eval()
    audio, rate = sf.read(args.input, dtype='float32', always_2d=True)
    if rate != model.samplerate or audio.shape[1] != 2 or not len(audio):
        raise ValueError('A entrada deve ser estéreo, 44.1 kHz, com áudio.')
    if not np.isfinite(audio).all():
        raise ValueError('O áudio contém amostras inválidas.')
    mix = torch.from_numpy(audio.T.copy())
    reference = mix.mean(0)
    mean, scale = reference.mean(), reference.std()
    device = 'mps' if torch.backends.mps.is_available() and args.device != 'cpu' else 'cpu'
    # Progress follows completed inference chunks, not an estimated timer.
    def progress_iterator(iterable, **kwargs):
        total = len(iterable)
        for index, entry in enumerate(iterable):
            status(0.05 + 0.85 * index / max(1, total), 'Separando os instrumentos…')
            yield entry
    apply.tqdm.tqdm = progress_iterator
    if float(scale) < 1e-8:
        # Silence/DC needs no inference. Preserve it in Other, without multiplying DC.
        result = torch.zeros((len(model.sources), 2, len(audio)))
        result[model.sources.index('other')] = mix
    else:
        with torch.inference_mode():
            result = apply.apply_model(model, ((mix - mean) / scale)[None], device=device,
                                       shifts=0, split=True, overlap=0.25, progress=True,
                                       num_workers=0)[0].cpu()
        result = result * scale + mean / len(model.sources)
    indices = {name: index for index, name in enumerate(model.sources)}
    stems = [result[indices[name]] for name in ('vocals', 'drums', 'bass', 'guitar')]
    stems.append(result[indices['other']] + result[indices['piano']])
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
    print(json.dumps(dict(sources=list(OUTPUTS), sampleRate=rate, frames=len(audio), device=device)), flush=True)


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
        (Path(args.output) / 'error.txt').write_text(str(error))
        sys.exit(1)
