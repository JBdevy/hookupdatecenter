#!/usr/bin/env python3
"""Small real-I/O worker test: accelerator failure must release its graph first.

No model inference or OpenVINO installation is needed. The failed backend is
injected; Torch still supplies real inference tensors and SoundFile writes the
five output files. Run with the bundled runtime's Python.
"""
import argparse
from contextlib import redirect_stderr, redirect_stdout
import gc
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
from unittest.mock import patch
import weakref

import numpy as np
import soundfile as sf
import torch
from demucs import apply, states


SOURCES = ['drums', 'bass', 'other', 'vocals', 'guitar', 'piano']


def load_worker(path):
    spec = importlib.util.spec_from_file_location('catstem_worker_fallback_test', path)
    worker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(worker)
    return worker


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worker', type=Path, required=True)
    args = parser.parse_args()
    worker = load_worker(args.worker)
    prior_progress = apply.tqdm.tqdm
    try:
        with tempfile.TemporaryDirectory(prefix='catstem-fallback-test-') as temporary:
            directory = Path(temporary)
            checkpoint = directory / 'test-model.th'
            checkpoint.write_bytes(b'failure-injection-only')
            worker.MODEL_HASH = hashlib.sha256(checkpoint.read_bytes()).hexdigest()
            timeline = np.arange(128, dtype=np.float32)
            source = np.stack((.2 + .1 * np.sin(timeline * .17),
                               .1 + .08 * np.cos(timeline * .31)), axis=1)
            sf.write(directory / 'input.wav', source, 44100, subtype='FLOAT')
            retired = []
            calls = []

            class FailedAccelerator:
                sources, samplerate, device_name = SOURCES, 44100, 'GPU'

                def forward(self, mix):
                    # The exception traceback owns this object through `self`.
                    # Holding the traceback during fallback retains the graph.
                    calls.append('accelerator-infer')
                    self.partial_prediction = torch.zeros(6, 2, 128)
                    raise RuntimeError('Injected GPU device loss during inference')

            def accelerator(*unused):
                graph = FailedAccelerator()
                retired.append(weakref.ref(graph))
                return graph

            class EagerModel:
                sources, samplerate = SOURCES, 44100

                def eval(self):
                    return self

                def forward(self, mix):
                    calls.append('eager-infer')
                    # This is an inference tensor. Post-normalization must use
                    # inference_mode too when updating it in-place.
                    result = mix[:, None].repeat(1, 6, 1, 1) / 6
                    assert torch.is_inference(result)
                    return result

            def eager(*unused):
                gc.collect()
                assert retired[0]() is None, 'Failed accelerator graph is still alive while loading the CPU fallback'
                calls.append('eager-load')
                return EagerModel()

            def infer(model, mix, **options):
                assert options['device'] == 'cpu'
                assert options['shifts'] == 0 and options['split'] and options['overlap'] == .25
                return model.forward(mix)

            stdout, stderr = io.StringIO(), io.StringIO()
            with patch.object(worker, 'accelerated_model', accelerator), \
                    patch.object(states, 'load_model', eager), \
                    patch.object(apply, 'apply_model', infer), \
                    patch.object(torch, 'set_num_threads'), \
                    patch.object(torch, 'set_num_interop_threads'), \
                    redirect_stdout(stdout), redirect_stderr(stderr):
                worker.separate(SimpleNamespace(model=str(checkpoint), input=str(directory / 'input.wav'),
                                                output=str(directory), device='auto'))
            assert calls == ['accelerator-infer', 'eager-load', 'eager-infer'], calls
            metadata = json.loads(stdout.getvalue().strip().splitlines()[-1])
            assert metadata['backend'] == 'torch' and metadata['device'] == 'cpu', metadata
            assert 'inference_fallback' in stderr.getvalue()
            stems = []
            for label in worker.OUTPUTS:
                samples, rate = sf.read(directory / (label + '.wav'), dtype='float32', always_2d=True)
                assert rate == 44100 and samples.shape == source.shape and np.isfinite(samples).all()
                stems.append(samples)
            assert np.max(np.abs(sum(stems) - source)) < 1e-6
            # The four explicit estimates include the original DC offset,
            # divided across all six model sources during denormalization.
            for samples in stems[:4]:
                assert np.max(np.abs(samples - source / 6)) < 1e-6
            assert json.loads((directory / 'progress.json').read_text())['fraction'] == 1

            helper = directory / 'offline_openvino.py'
            helper.write_text('''
class Core:
    available_devices = ['GPU', 'CPU']
class ov:
    Core = Core
class OfflineOpenVINOModel:
    def __init__(self, model_path, device):
        if device == 'GPU': raise RuntimeError('Injected unavailable GPU')
        self.device_name = device
''', encoding='utf-8')
            worker.__file__ = str(directory / 'separate.py')
            with patch.object(worker.sys, 'platform', 'win32'), redirect_stderr(io.StringIO()):
                selected = worker.accelerated_model(checkpoint, 'auto', lambda *_: None)
                assert selected.device_name == 'CPU', 'GPU setup failure did not try CPU acceleration'
                assert worker.accelerated_model(checkpoint, 'cpu', lambda *_: None) is None
                helper.write_text('raise RuntimeError("Injected helper import failure")', encoding='utf-8')
                assert worker.accelerated_model(checkpoint, 'auto', lambda *_: None) is None
                helper.unlink()
                assert worker.accelerated_model(checkpoint, 'auto', lambda *_: None) is None
            print('WORKER_ACCELERATOR_RELEASE_FALLBACK_INFERENCE_NORMALIZATION_AND_OUTPUTS_OK')
    finally:
        apply.tqdm.tqdm = prior_progress


if __name__ == '__main__':
    main()
