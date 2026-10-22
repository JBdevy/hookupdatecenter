#!/usr/bin/env python3
"""Numerical regression checks for the FP32 CatStem streaming optimizations.

Run with the prepared runtime's Python. The packaging converter additionally
compares every real checkpoint source against eager PyTorch on three fixtures.
"""
from pathlib import Path
import importlib.util
import sys
import unittest

spec = importlib.util.spec_from_file_location('catstem_backend', Path(__file__).with_name('openvino_backend.py'))
backend = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backend)
np, torch, ov = backend.np, backend.torch, backend.ov
from openvino import opset13 as ops


class StreamingMathTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        backend.configure_torch()

    def test_windowed_istft_preserves_every_source_at_boundaries(self):
        generator = np.random.default_rng(107)
        frequency = torch.from_numpy(generator.normal(0, .03, (1, 6, 4, 2048, 44)).astype(np.float32))
        temporal = torch.from_numpy(generator.normal(0, .03, (1, 6, 2, 44100)).astype(np.float32))
        transform = backend.SpectralTransform(4096, 1024)
        full = transform.decode(frequency, temporal, 44100)
        for start, end in ((0, 1), (0, 8192), (1001, 3000), (32836, 42052),
                           (35000, 44100), (44099, 44100), (0, 44100)):
            with self.subTest(start=start, end=end):
                window = transform.decode_window(frequency, temporal, 44100, start, end)
                self.assertEqual(tuple(window.shape), (1, 6, 2, end - start))
                self.assertTrue(torch.equal(window, full[..., start:end]))
                named = transform.decode_named_window(frequency, temporal, 44100, start, end)
                self.assertTrue(torch.equal(named, full[:, [3, 0, 1, 4], :, start:end]))

    def test_named_istft_and_residual_preserve_all_five_wire_sources(self):
        shared = Path(__file__).with_name('stream.py')
        if not shared.exists():
            shared = Path(__file__).parents[2] / 'Apple/Resources/StemSeparation/stream.py'
        spec = importlib.util.spec_from_file_location('catstem_test_protocol', shared)
        protocol = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = protocol
        spec.loader.exec_module(protocol)
        transform = backend.SpectralTransform(4096, 1024)

        class FixtureBackend(protocol.StreamingBackend):
            def __init__(self, crossfade, named_only):
                self.np, self.crossfade, self.named_only = np, crossfade, named_only
                self.context = np.zeros((2, 44100), np.float32)
                self.previous_tail = None
                self.skipped_silent_blocks = 0
                self.fade = np.linspace(0, 1, crossfade, dtype=np.float32)[None, None, :] if crossfade else None

            def estimate(self):
                start, end = 32836, 41028 + self.crossfade
                if self.named_only:
                    named = transform.decode_named_window(self.frequency, self.temporal, 44100, start, end)[0]
                    result = np.zeros((5, 2, end - start), np.float32)
                    result[:4] = named.numpy()
                    return result
                pcm = transform.decode_window(self.frequency, self.temporal, 44100, start, end)[0]
                return torch.stack([pcm[3], pcm[0], pcm[1], pcm[4], pcm[2] + pcm[5]]).numpy().copy()

        generator = np.random.default_rng(109)
        for crossfade in (0, 1024, 3072):
            original, optimized = FixtureBackend(crossfade, False), FixtureBackend(crossfade, True)
            for block in range(8):
                with self.subTest(crossfade=crossfade, block=block):
                    frequency = torch.from_numpy(generator.normal(0, .03, (1, 6, 4, 2048, 44)).astype(np.float32))
                    temporal = torch.from_numpy(generator.normal(0, .03, (1, 6, 2, 44100)).astype(np.float32))
                    payload = generator.normal(0, .03, (8192, 2)).astype('<f4').tobytes()
                    for instance in (original, optimized):
                        instance.frequency, instance.temporal = frequency, temporal
                    self.assertEqual(original.process(payload), optimized.process(payload))

    def test_polyphase_and_expanded_dilation_preserve_pcm_and_bias(self):
        generator = np.random.default_rng(108)
        core = ov.Core()
        for spatial_rank in (1, 2):
            with self.subTest(spatial_rank=spatial_rank):
                data = ops.parameter([1, 3, 17], ov.Type.f32, name='pcm')
                weights = generator.normal(0, .1, (5, 3, 3)).astype(np.float32)
                convolved = ops.convolution(data, ops.constant(weights), [1], [2], [2], [2])
                if spatial_rank == 2:
                    convolved = ops.unsqueeze(convolved, ops.constant([3], np.int64))
                kernel = (5, 2, 8) if spatial_rank == 1 else (5, 2, 8, 1)
                coefficients = generator.normal(0, .1, kernel).astype(np.float32)
                strides = [4] if spatial_rank == 1 else [4, 1]
                deconvolved = ops.convolution_backprop_data(convolved, ops.constant(coefficients), strides,
                                                           pads_begin=[0] * spatial_rank, pads_end=[0] * spatial_rank,
                                                           dilations=[1] * spatial_rank)
                bias = ops.constant(np.array([.013, -.027], np.float32).reshape(1, 2, *([1] * spatial_rank)))
                model = ov.Model([ops.add(deconvolved, bias)], [data])
                changed = model.clone()
                counts = backend.optimize_network_graph(changed)
                self.assertEqual(counts, {'polyphaseConvolutions': 1, 'expandedDilations': 1})
                options = {'INFERENCE_PRECISION_HINT': 'f32', 'INFERENCE_NUM_THREADS': 2}
                original, optimized = core.compile_model(model, 'CPU', options), core.compile_model(changed, 'CPU', options)
                for amplitude in (.0001, .03, .7):
                    fixture = generator.normal(0, amplitude, (1, 3, 17)).astype(np.float32)
                    expected = original({0: fixture})[original.output(0)]
                    actual = optimized({0: fixture})[optimized.output(0)]
                    np.testing.assert_allclose(actual, expected, atol=2e-7, rtol=2e-5)


if __name__ == '__main__':
    unittest.main()
