#!/usr/bin/env python3
"""Windows CatStem inference worker using the shared Mac CST1/PCM contract.

Runtime/model files are prepared at build time. No download takes place in this
worker. Native callback/pipe integration is a separate Windows host component.
"""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import time


def load_protocol():
    bundled = Path(__file__).with_name('stream.py')
    source = Path(__file__).resolve().parents[2] / 'Apple/Resources/StemSeparation/stream.py'
    path = bundled if bundled.is_file() else source
    spec = importlib.util.spec_from_file_location('catstem_protocol', path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


protocol = load_protocol()


class TorchBackend(protocol.StreamingBackend):
    def __init__(self, model, device='auto', crossfade_frames=1024):
        if not 0 <= crossfade_frames <= min(protocol.RIGHT, protocol.HOP):
            raise ValueError('Crossfade must fit within captured right context')
        model = Path(model)
        with model.open('rb') as source:
            digest = hashlib.file_digest(source, 'sha256').hexdigest()
        if digest != protocol.SOURCE_SHA:
            raise ValueError('CatStem model SHA256 mismatch')
        import numpy as np
        import torch
        from demucs.states import load_model
        torch.set_num_threads(max(1, min(4, (os.cpu_count() or 2) // 2)))
        torch.set_num_interop_threads(1)
        torch.manual_seed(0)
        self.device = 'cuda' if device == 'auto' and torch.cuda.is_available() else ('cpu' if device == 'auto' else device)
        if self.device == 'cuda' and not torch.cuda.is_available():
            raise RuntimeError('CUDA is not available in this runtime/device')
        # Only the pinned checkpoint above is deserialized; never project data.
        self.model = load_model(model).eval().to(self.device)
        if list(self.model.sources) != protocol.SOURCES or self.model.samplerate != protocol.RATE:
            raise ValueError('Unexpected CatStem source/sample-rate contract')
        self.model.segment = protocol.CONTEXT / protocol.RATE
        self.np, self.torch = np, torch
        self.crossfade = crossfade_frames
        self.context = np.zeros((protocol.CHANNELS, protocol.CONTEXT), dtype=np.float32)
        self.previous_tail = None
        self.skipped_silent_blocks = 0
        self.fade = np.linspace(0, 1, crossfade_frames, dtype=np.float32)[None, None, :] if crossfade_frames else None
        self.model_sha = digest

    def estimate(self):
        with self.torch.inference_mode():
            pcm = self.torch.from_numpy(self.context[None].copy()).to(self.device)
            start = protocol.CONTEXT - protocol.RIGHT - protocol.HOP
            end = protocol.CONTEXT - protocol.RIGHT + self.crossfade
            predicted = self.model(pcm)[0, :, :, start:end]
            output = self.torch.stack([predicted[3], predicted[0], predicted[1], predicted[4], predicted[2] + predicted[5]])
            output = output.cpu().numpy().copy(order='C')
        if output.shape != (protocol.STEMS, protocol.CHANNELS, protocol.HOP + self.crossfade) or not self.np.isfinite(output).all():
            raise ValueError('Nonfinite or malformed CatStem output')
        return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--device', choices=['auto', 'cpu', 'cuda'], default='auto')
    parser.add_argument('--crossfade-frames', type=int, default=1024)
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--benchmark', action='store_true')
    args = parser.parse_args()
    destination = sys.stdout.buffer
    try:
        with contextlib.redirect_stdout(sys.stderr):
            backend = TorchBackend(args.model, args.device, args.crossfade_frames)
            warmup = backend.warmup()
            # Include non-silent inference, not merely the silence fast path.
            rng = backend.np.random.default_rng(0)
            pcm = rng.normal(0, .03, (protocol.HOP, 2)).astype('<f4')
            began = time.perf_counter()
            output = backend.process(pcm.tobytes())
            elapsed = time.perf_counter() - began
            stems = backend.np.frombuffer(output, dtype='<f4').reshape(5, protocol.HOP, 2)
            start = protocol.CONTEXT - protocol.RIGHT - protocol.HOP
            aligned = backend.context[:, start:start + protocol.HOP].T
            error = float(backend.np.max(backend.np.abs(stems.sum(axis=0) - aligned)))
            backend.reset()
        report = {'backend': 'torch-htdemucs6', 'device': backend.device,
                  'modelSHA': backend.model_sha, 'warmupSeconds': warmup,
                  'nonSilentSeconds': elapsed, 'computeBudgetSeconds': protocol.COMPUTE_BUDGET,
                  'reconstructionMaximumError': error,
                  'realtimeEligible': max(warmup[-2:] + [elapsed]) <= protocol.COMPUTE_BUDGET
                      and sum(warmup[-2:] + [elapsed]) / 3 <= protocol.HOP / protocol.RATE}
        if error > 1e-5:
            raise RuntimeError('CatStem mixture consistency validation failed')
        if args.benchmark:
            print(json.dumps(report, allow_nan=False))
            return 0
        if not args.offline and not report['realtimeEligible']:
            raise RuntimeError('This device/runtime cannot process CatStem within the realtime audio deadline; offline rendering remains available')
        ready = dict(report, protocolVersion=protocol.VERSION, sampleRate=protocol.RATE,
                     channels=2, stems=5, hopFrames=protocol.HOP, contextFrames=protocol.CONTEXT,
                     rightContextFrames=protocol.RIGHT, latencyFrames=protocol.LATENCY,
                     maxStreams=1, maxQueuedAudio=protocol.MAX_INPUT_QUEUE,
                     outputNames=protocol.OUTPUT_NAMES, crossfadeFrames=backend.crossfade,
                     sourceCheckpointSHA=protocol.SOURCE_SHA, offlineRendering=args.offline)
        return protocol.Service(backend, sys.stdin.buffer, destination, offline=args.offline).run(ready)
    except Exception as error:
        print(json.dumps({'event': 'fatal', 'message': str(error)}), file=sys.stderr, flush=True)
        if args.benchmark:
            print(json.dumps({'success': False, 'error': str(error)}))
        else:
            with contextlib.suppress(BrokenPipeError):
                destination.write(protocol.error_packet('BACKEND_UNAVAILABLE', str(error), recoverable=False).encode())
                destination.flush()
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
