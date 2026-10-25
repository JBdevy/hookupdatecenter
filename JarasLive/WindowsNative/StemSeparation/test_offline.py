"""Real bundled offline-worker regression; fixtures stay outside app resources."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import numpy as np
import soundfile as sf


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--worker', type=Path, required=True)
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--device', choices=['auto', 'cpu'], default='auto')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    rate = 44100
    frames = np.arange(rate, dtype=np.float32)
    source = np.stack((.1 * np.sin(frames * .034) + .04 * np.sin(frames * .09), .08 * np.sin(frames * .042)), axis=1)
    sf.write(args.output / 'input.wav', source, rate, subtype='FLOAT')
    worker = subprocess.run([sys.executable, '-I', '-B', str(args.worker), '--input', str(args.output / 'input.wav'),
                             '--output', str(args.output), '--model', str(args.model), '--device', args.device],
                            check=True, stdout=subprocess.PIPE, text=True, encoding='utf-8')
    # The default Windows path must actually load the bundled accelerator. A
    # silent fallback could otherwise pass the same unity/output checks while
    # shipping an incomplete package and retaining the slow eager execution.
    metadata = json.loads(worker.stdout.strip().splitlines()[-1])
    backend = metadata['backend']
    if args.device == 'cpu':
        assert backend == 'torch' and metadata['device'] == 'cpu', metadata
    elif sys.platform == 'win32':
        assert backend in ('openvino-cpu', 'openvino-gpu'), metadata
    assert metadata['sources'] == ['Vocal', 'Drum', 'Bass', 'Guitar', 'Other'], metadata
    assert metadata['sampleRate'] == rate and metadata['frames'] == len(source), metadata
    outputs = []
    for label in ['Vocal', 'Drum', 'Bass', 'Guitar', 'Other']:
        audio, hz = sf.read(args.output / (label + '.wav'), dtype='float32', always_2d=True)
        assert hz == rate and audio.shape == source.shape and np.isfinite(audio).all(), label
        outputs.append(audio)
    error = float(np.max(np.abs(sum(outputs) - source)))
    assert error < 1e-6, error
    status = json.loads((args.output / 'progress.json').read_text(encoding='utf-8'))
    assert status['fraction'] == 1, status
    print(json.dumps(dict(result='OFFLINE_FIVE_STEMS_EXACT_DURATION_UNITY_OK', frames=len(source),
                          reconstructionError=error, requestedDevice=args.device, backend=backend)), flush=True)


if __name__ == '__main__':
    main()
