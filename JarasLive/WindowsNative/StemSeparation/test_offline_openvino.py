#!/usr/bin/env python3
"""Real-model regression for full-context offline inference and file boundaries.

Run with the prepared Windows runtime's Python. Every source is checked against
the original eager checkpoint before Other is replaced by the mixture residual.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--device', choices=['CPU', 'GPU'], default='CPU')
    args = parser.parse_args()
    runtime = args.runtime.resolve()
    spec = importlib.util.spec_from_file_location('catstem_offline_test', runtime / 'offline_openvino.py')
    backend = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(backend)
    np, torch = backend.np, backend.torch
    from demucs import apply
    from demucs.states import load_model

    checkpoint = runtime / '5c90dfd2-34c22ccb.th'
    original = load_model(checkpoint).eval()
    model = backend.OfflineOpenVINOModel(checkpoint, device=args.device)
    assert original.segment == model.segment
    assert original.sources == model.sources
    assert original.samplerate == model.samplerate
    assert original.audio_channels == model.audio_channels
    assert model.valid_length(1) == model.valid_length(backend.CONTEXT) == backend.CONTEXT
    try:
        model.valid_length(backend.CONTEXT + 1)
    except ValueError:
        pass
    else:
        raise AssertionError('The fixed graph accepted an oversized window')

    # Nine seconds exercises two full-context calls, their overlap, and the
    # centered context padding of the final short chunk. Transients straddle
    # the exact stride to expose a changed trim, window, normalization or order.
    count = 9 * backend.RATE
    timeline = np.arange(count, dtype=np.float32) / backend.RATE
    rng = np.random.default_rng(104)
    fixture = rng.normal(0, .025, (2, count)).astype(np.float32)
    fixture[0] += .12 * np.sin(timeline * 2 * np.pi * 220)
    fixture[1] += .08 * np.sin(timeline * 2 * np.pi * 660)
    stride = int(.75 * backend.CONTEXT)
    fixture[:, stride - 1:stride + 2] += .4
    fixture[:, -2:] -= .2
    mix = torch.from_numpy(fixture[None])
    options = dict(shifts=0, split=True, overlap=.25, device='cpu', num_workers=0)
    with torch.inference_mode():
        backend.shared.configure_torch()
        started = time.monotonic()
        expected = apply.apply_model(original, mix, **options).numpy()
        eager_seconds = time.monotonic() - started
        backend.shared.configure_torch(1 if args.device == 'GPU' else None)
        started = time.monotonic()
        actual = apply.apply_model(model, mix, **options).numpy()
        optimized_seconds = time.monotonic() - started
    assert actual.shape == expected.shape == (1, 6, 2, count)
    assert np.isfinite(actual).all()
    sources = []
    for index, label in enumerate(model.sources):
        delta = (actual[:, index] - expected[:, index]).astype(np.float64)
        reference = expected[:, index].astype(np.float64)
        maximum = float(np.abs(delta).max())
        relative = float(np.sqrt(np.mean(delta ** 2)) / max(1e-12, np.sqrt(np.mean(reference ** 2))))
        assert maximum <= 2e-5 and relative <= .001, (label, maximum, relative)
        sources.append(dict(source=label, maximumAbsoluteError=maximum, relativeRMSError=relative))
    print(json.dumps(dict(result='OFFLINE_FULL_CONTEXT_ALL_SOURCES_OVERLAP_AND_TAIL_OK',
                          device=args.device, contextFrames=backend.CONTEXT, frames=count,
                          eagerSeconds=eager_seconds, optimizedSeconds=optimized_seconds,
                          sources=sources)), flush=True)


if __name__ == '__main__':
    main()
