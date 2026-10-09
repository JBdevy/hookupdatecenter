#!/usr/bin/env python3
"""Read authorized project stems into a local validation mixture; never edit project."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import unicodedata


def fold(text):
    return ''.join(c for c in unicodedata.normalize('NFD', text.casefold()) if not unicodedata.combining(c))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--project-json', type=Path, required=True)
    p.add_argument('--project-dir', type=Path, required=True)
    p.add_argument('--title', required=True)
    p.add_argument('--start', type=float, default=30)
    p.add_argument('--seconds', type=float, default=30)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    import numpy as np
    import soundfile as sf
    project = json.loads(args.project_json.read_text())
    paths = set()
    for song in project.get('songs', []):
        for track in song.get('tracks', []):
            for clip in track.get('clips', []):
                asset = clip.get('audioFile') or track.get('audioFile') or {}
                name = asset.get('path', '')
                key = fold(Path(name).name)
                if name.lower().endswith('.wav') and fold(args.title) in key and not any(x in key for x in ['regencia', 'metronomo', 'guia', 'click']):
                    path = (args.project_dir / name).resolve()
                    path.relative_to(args.project_dir.resolve())
                    paths.add(path)
    if not paths:
        raise ValueError('No matching musical stems')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    count = round(args.seconds * 44100)
    mixture = np.zeros((count, 2), dtype=np.float32)
    sources = []
    with tempfile.TemporaryDirectory(prefix='catstem-fixture-', dir=args.output.parent) as scratch:
        for index, path in enumerate(sorted(paths)):
            with sf.SoundFile(path) as f:
                rate, channels = f.samplerate, f.channels
                if channels not in [1, 2]:
                    raise ValueError(f'Explicit downmix needed for {channels} channels: {path.name}')
                if round(args.start * rate) >= len(f):
                    continue
                f.seek(round(args.start * rate))
                data = f.read(round(args.seconds * rate), dtype='float32', always_2d=True)
            if channels == 1:
                data = np.repeat(data, 2, axis=1)
            if rate != 44100:
                source = Path(scratch) / f'{index}-source.wav'
                converted = Path(scratch) / f'{index}-44100.wav'
                sf.write(source, data, rate, subtype='FLOAT')
                subprocess.run(['/usr/bin/afconvert', '-f', 'WAVE', '-d', 'LEF32@44100', '-r', '127', str(source), str(converted)], check=True)
                data, _ = sf.read(converted, dtype='float32', always_2d=True)
            n = min(count, len(data))
            mixture[:n] += data[:n]
            sources.append({'path': str(path), 'originalRate': rate, 'channels': channels,
                            'framesUsed': n, 'rms': float(np.sqrt(np.mean(data[:n].astype(np.float64) ** 2)))})
    peak = float(np.max(np.abs(mixture)))
    if peak <= 1e-8 or not np.isfinite(mixture).all():
        raise ValueError('Fixture is silent or nonfinite')
    gain = .5 / peak
    mixture *= gain
    sf.write(args.output, mixture, 44100, subtype='FLOAT')
    metadata = {'purpose': 'local separator validation mixture, not a project master export',
                'startSeconds': args.start, 'seconds': args.seconds, 'normalizationGain': gain,
                'sourceFiles': sources, 'output': str(args.output)}
    args.output.with_suffix('.json').write_text(json.dumps(metadata, indent=2))
    print(json.dumps(metadata), flush=True)


if __name__ == '__main__':
    main()
