#!/usr/bin/env python3
"""CST1 framing/epoch/backpressure tests; no MLX, torch or audio device."""
import importlib.util
import io
from pathlib import Path
import socket
import struct
import sys
import threading
import time
import unittest

sys.dont_write_bytecode = True
WORKER = Path(__file__).resolve().parents[2] / 'Apple/Resources/StemSeparation/stream.py'
spec = importlib.util.spec_from_file_location('catstem_stream', WORKER)
stream = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = stream
spec.loader.exec_module(stream)


def audio(sequence=0, generation=1, first_frame=None):
    return stream.Packet(stream.AUDIO, 9, generation, sequence,
                         sequence * stream.HOP if first_frame is None else first_frame,
                         stream.RATE, stream.HOP, 2, 0,
                         bytes(stream.HOP * 2 * 4), received=time.perf_counter())


class Fragmented(io.BytesIO):
    def read(self, n=-1):
        return super().read(min(n, 13))


class ControlledBackend:
    """Only a protocol fixture; never offered as a real separation backend."""
    def __init__(self):
        self.entered = threading.Event()
        self.release = threading.Event()
        self.calls = 0
        self.resets = 0

    def reset(self):
        self.resets += 1

    def process(self, payload):
        self.calls += 1
        if self.calls == 1:
            self.entered.set()
            self.release.wait(2)
        return bytes(stream.HOP * 2 * 5 * 4)


class ProtocolTests(unittest.TestCase):
    @unittest.skipUnless(importlib.util.find_spec('numpy'), 'NumPy is optional for protocol-only tests')
    def test_exact_silence_skips_gpu_but_quiet_context_does_not(self):
        import numpy as np
        backend = object.__new__(stream.MLXBackend)
        backend.np = np
        backend.crossfade = 16
        backend.context = np.zeros((2, stream.CONTEXT), dtype=np.float32)
        backend.previous_tail = np.ones((5, 2, 16), dtype=np.float32)
        backend.fade = np.linspace(0, 1, 16, dtype=np.float32)[None, None, :]
        backend.skipped_silent_blocks = 0
        calls = []
        def estimate():
            calls.append(True)
            return np.zeros((5, 2, stream.HOP + 16), dtype=np.float32)
        backend.estimate = estimate
        result = np.frombuffer(backend.process(bytes(stream.HOP * 8)), dtype='<f4').reshape(5, stream.HOP, 2)
        self.assertFalse(calls)
        self.assertEqual(backend.skipped_silent_blocks, 1)
        self.assertEqual(result[0, 0, 0], 1)
        self.assertEqual(result[0, 15, 0], 0)
        quiet = np.zeros((stream.HOP, 2), dtype='<f4')
        quiet[-1, 0] = 1e-20
        backend.process(quiet.tobytes())
        self.assertEqual(len(calls), 1)
        backend.process(bytes(stream.HOP * 8))
        self.assertEqual(len(calls), 2)  # quiet signal still exists in past context

    def test_fragmented_header_and_signed_source_clock(self):
        original = stream.Packet(stream.OUTPUT, 4, 7, 8, -3072, stream.RATE,
                                 3, 2, 5, struct.pack('<30f', *range(30)))
        parsed = stream.read_packet(Fragmented(original.encode()))
        self.assertEqual(stream.HEADER.size, 64)
        self.assertEqual(parsed.first_frame, -3072)
        self.assertEqual(parsed.payload, original.payload)
        self.assertEqual(parsed.generation, 7)

    def test_rejects_truncation_and_unbounded_allocation(self):
        with self.assertRaises(stream.ProtocolError):
            stream.read_packet(io.BytesIO(audio().encode()[:-1]))
        raw = bytearray(audio().encode()[:64])
        struct.pack_into('<I', raw, 52, stream.MAX_PAYLOAD + 1)
        with self.assertRaises(stream.ProtocolError):
            stream.read_packet(io.BytesIO(raw))

    def test_requires_flush_and_canonical_format(self):
        box = stream.Mailbox()
        self.assertEqual(box.accept(audio())[0].kind, stream.ERROR)
        self.assertFalse(box.valid)
        box.accept(stream.Packet(stream.FLUSH, 9, 1))
        box.take()
        bad = stream.replace(audio(), sample_rate=48000)
        self.assertEqual(box.accept(bad)[0].kind, stream.ERROR)
        self.assertFalse(box.valid)

    def test_backpressure_invalidates_epoch_instead_of_accumulating_delay(self):
        box = stream.Mailbox()
        box.accept(stream.Packet(stream.FLUSH, 9, 1))
        box.take()
        self.assertFalse(box.accept(audio(0)))
        self.assertFalse(box.accept(audio(1)))
        errors = box.accept(audio(2))
        self.assertIn(b'OVERLOAD', errors[0].payload)
        self.assertFalse(box.valid)
        self.assertEqual(len(box.jobs), 0)

    def test_flush_drops_old_epoch_and_restarts_source_clock(self):
        box = stream.Mailbox()
        box.accept(stream.Packet(stream.FLUSH, 9, 1))
        box.take()
        first = audio()
        box.accept(first)
        old_inflight = box.take()
        box.accept(stream.Packet(stream.FLUSH, 9, 2, first_frame=50000))
        self.assertFalse(box.current(old_inflight))
        self.assertEqual(box.take().generation, 2)
        self.assertFalse(box.accept(audio(generation=2, first_frame=50000)))
        self.assertEqual(box.next_frame, 50000 + stream.HOP)
        self.assertFalse(box.accept(first))  # stale in-flight input is discarded

    def test_service_never_publishes_result_from_flush_race(self):
        client, server = socket.socketpair()
        client.settimeout(3)
        incoming = server.makefile('rb', buffering=0)
        outgoing = server.makefile('wb', buffering=0)
        source = client.makefile('rb', buffering=0)
        sink = client.makefile('wb', buffering=0)
        backend = ControlledBackend()
        service = stream.Service(backend, incoming, outgoing)
        thread = threading.Thread(target=service.run, args=({'protocolVersion': 1},), daemon=True)
        thread.start()
        try:
            self.assertEqual(stream.read_packet(source).kind, stream.READY)
            client.sendall(stream.Packet(stream.FLUSH, 9, 1).encode())
            self.assertEqual(stream.read_packet(source).kind, stream.FLUSHED)
            client.sendall(audio().encode())
            self.assertTrue(backend.entered.wait(1))
            client.sendall(stream.Packet(stream.FLUSH, 9, 2).encode())
            deadline = time.monotonic() + 1
            while service.mailbox.generation != 2 and time.monotonic() < deadline:
                time.sleep(.001)
            backend.release.set()
            packet = stream.read_packet(source)
            self.assertEqual((packet.kind, packet.generation), (stream.FLUSHED, 2))
            client.sendall(audio(generation=2).encode())
            packet = stream.read_packet(source)
            self.assertEqual((packet.kind, packet.generation, packet.first_frame), (stream.OUTPUT, 2, -3072))
            self.assertEqual(len(packet.payload), stream.HOP * 2 * 5 * 4)
            client.sendall(stream.Packet(stream.CLOSE).encode())
            self.assertEqual(stream.read_packet(source).kind, stream.CLOSED)
            thread.join(2)
            self.assertFalse(thread.is_alive())
            self.assertEqual(backend.resets, 2)
        finally:
            backend.release.set()
            for handle in [source, sink, incoming, outgoing, client, server]:
                handle.close()


if __name__ == '__main__':
    unittest.main()
