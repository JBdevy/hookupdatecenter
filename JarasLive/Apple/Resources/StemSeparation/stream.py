#!/usr/bin/env python3
"""Persistent CatStem PCM worker. stdout is exclusively the CST1 binary protocol.

The native audio callback communicates with its own bounded rings. Dedicated
native I/O threads communicate with this process; pipes never belong in the
render callback. This worker accepts only canonical 44.1 kHz stereo float PCM.
Model/runtime preparation is a build-time concern; no downloads or conversion
are performed here. macOS 12/13 and Intel have no MLX streaming capability.
"""
from __future__ import annotations

import argparse
from collections import deque
import contextlib
from dataclasses import dataclass, replace
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import queue
import struct
import sys
import threading
import time

MAGIC = b'CST1'
VERSION = 1
HEADER = struct.Struct('<4sHHQQQqIIHHIII')
READY, AUDIO, OUTPUT, FLUSH, FLUSHED, ERROR, CLOSE, CLOSED = range(1, 9)
RATE, CHANNELS, STEMS = 44100, 2, 5
HOP, CONTEXT, RIGHT, LATENCY = 8192, 44100, 3072, 24576
MAX_INPUT_QUEUE, MAX_OUTPUT_QUEUE = 2, 4
MAX_PAYLOAD = HOP * CHANNELS * STEMS * 4
SOURCE_SHA = '34c22ccb381c6f9fdbf324f04e1e2fe21aaaf293f5ded163a162697ff9a02ddd'
SOURCES = ['drums', 'bass', 'other', 'vocals', 'guitar', 'piano']
OUTPUT_NAMES = ['Vocal', 'Drum', 'Bass', 'Guitar', 'Other']
COMPUTE_BUDGET = (LATENCY - HOP - RIGHT) / RATE


class ProtocolError(ValueError):
    pass


@dataclass(frozen=True)
class Packet:
    kind: int
    stream: int = 0
    generation: int = 0
    sequence: int = 0
    first_frame: int = 0
    sample_rate: int = RATE
    frames: int = 0
    channels: int = 0
    stems: int = 0
    payload: bytes = b''
    flags: int = 0
    received: float = 0.0

    def encode(self):
        return HEADER.pack(MAGIC, VERSION, self.kind, self.stream, self.generation,
                           self.sequence, self.first_frame, self.sample_rate, self.frames,
                           self.channels, self.stems, len(self.payload), self.flags, 0) + self.payload


def _read_exact(source, count, eof_ok=False):
    chunks = bytearray()
    while len(chunks) < count:
        part = source.read(count - len(chunks))
        if not part:
            if eof_ok and not chunks:
                return None
            raise ProtocolError('Truncated packet')
        chunks.extend(part)
    return bytes(chunks)


def read_packet(source):
    raw = _read_exact(source, HEADER.size, eof_ok=True)
    if raw is None:
        return None
    magic, version, kind, stream, generation, seq, first, rate, frames, channels, stems, size, flags, reserved = HEADER.unpack(raw)
    if magic != MAGIC or version != VERSION or reserved or flags:
        raise ProtocolError('Unsupported protocol header')
    if kind not in range(READY, CLOSED + 1) or size > MAX_PAYLOAD:
        raise ProtocolError('Invalid message type or payload size')
    data = _read_exact(source, size) if size else b''
    return Packet(kind, stream, generation, seq, first, rate, frames, channels, stems,
                  data, flags, time.perf_counter())


def json_packet(kind, data, request=None):
    packet = request or Packet(kind)
    return replace(packet, kind=kind, frames=0, channels=0, stems=0,
                   payload=json.dumps(data, separators=(',', ':'), allow_nan=False).encode('utf8'))


def error_packet(code, message, request=None, recoverable=True):
    return json_packet(ERROR, {'code': code, 'message': message, 'recoverable': recoverable}, request)


class Mailbox:
    """Reader-owned admission and generation barrier; inference never holds its lock."""
    def __init__(self):
        self.condition = threading.Condition()
        self.jobs = deque()
        self.stream = 0
        self.generation = 0
        self.next_sequence = 0
        self.next_frame = 0
        self.valid = False
        self.closed = False

    def _invalidate(self):
        self.valid = False
        self.jobs.clear()

    def current(self, packet):
        with self.condition:
            return self.valid and not self.closed and packet.stream == self.stream and packet.generation == self.generation

    def invalidate(self, packet):
        with self.condition:
            if packet.stream == self.stream and packet.generation == self.generation:
                self._invalidate()
                self.condition.notify_all()

    def accept(self, packet):
        with self.condition:
            if self.closed:
                return []
            if packet.kind == CLOSE:
                if packet.payload or packet.frames:
                    return [error_packet('BAD_CONTROL', 'CLOSE has no payload', packet)]
                self.closed = True
                self._invalidate()
                self.jobs.append(packet)
                self.condition.notify_all()
                return []
            if packet.kind == FLUSH:
                if packet.payload or packet.frames or not packet.stream or packet.sequence:
                    return [error_packet('BAD_CONTROL', 'FLUSH needs a stream, sequence zero and no PCM', packet)]
                if self.stream and packet.stream != self.stream:
                    return [error_packet('STREAM_LIMIT', 'This worker admits one stream', packet)]
                if packet.generation <= self.generation:
                    return [error_packet('STALE_GENERATION', 'FLUSH generation must increase', packet)]
                self.stream, self.generation = packet.stream, packet.generation
                self.next_sequence, self.next_frame = 0, packet.first_frame
                self.valid = True
                self.jobs.clear()
                self.jobs.append(packet)
                self.condition.notify_all()
                return []
            if packet.kind != AUDIO:
                return [error_packet('BAD_DIRECTION', 'Host may send AUDIO, FLUSH or CLOSE', packet)]
            if packet.generation < self.generation:
                return []  # A writer may already have an old epoch packet in flight.
            if not self.valid or packet.stream != self.stream or packet.generation != self.generation:
                return [error_packet('FLUSH_REQUIRED', 'Send FLUSH and wait for FLUSHED before PCM', packet)]
            if (packet.sample_rate, packet.frames, packet.channels, packet.stems, len(packet.payload)) != (RATE, HOP, CHANNELS, 0, HOP * CHANNELS * 4):
                self._invalidate()
                return [error_packet('BAD_FORMAT', 'PCM must be 8192 frames of 44.1 kHz interleaved stereo float32', packet)]
            if packet.sequence != self.next_sequence or packet.first_frame != self.next_frame:
                self._invalidate()
                return [error_packet('DISCONTINUITY', 'Sequence or source clock discontinuity; FLUSH required', packet)]
            if sum(job.kind == AUDIO for job in self.jobs) >= MAX_INPUT_QUEUE:
                self._invalidate()
                return [error_packet('OVERLOAD', 'Input queue full; FLUSH required', packet)]
            self.next_sequence += 1
            self.next_frame += HOP
            self.jobs.append(packet)
            self.condition.notify_all()
            return []

    def take(self):
        with self.condition:
            while not self.jobs:
                if self.closed:
                    return None
                self.condition.wait(.1)
            return self.jobs.popleft()


class MLXBackend:
    def __init__(self, model_dir, crossfade_frames=1024):
        if crossfade_frames < 0 or crossfade_frames > RIGHT or crossfade_frames > HOP:
            raise ValueError('Crossfade must fit within the captured right context')
        os.environ['HF_HUB_OFFLINE'] = '1'
        os.environ['DEMUCS_MLX_NO_DOWNLOAD'] = '1'
        os.environ['DEMUCS_MLX_ATTENTION_FP16'] = '0'
        os.environ['DEMUCS_MLX_COMPILE_FORWARD'] = '1'
        import numpy as np
        import mlx.core as mx
        from demucs_mlx import mlx_convert
        from demucs_mlx.apply_mlx import _forward
        from demucs_mlx.mlx_transformer import FastMultiHeadAttention
        mx.set_default_device(mx.gpu)
        mx.set_cache_limit(256 * 1024 * 1024)
        model_dir = Path(model_dir)
        config = json.loads((model_dir / 'htdemucs_6s_config.json').read_text())
        if config.get('source_artifacts') != [{'checksum': '34c22ccb', 'signature': '5c90dfd2'}]:
            raise ValueError('Unexpected model source identity')
        weights = model_dir / 'htdemucs_6s.safetensors'
        with weights.open('rb') as handle:
            digest = hashlib.file_digest(handle, 'sha256').hexdigest()
        if digest != config.get('safetensors_sha256'):
            raise ValueError('Model SHA256 mismatch')
        # Never write a verified-inode cache into signed app Resources. The
        # complete digest above and the loader's own validation remain active.
        mlx_convert._write_verified_stamp = lambda *args, **kwargs: None
        mlx_convert._stamp_matches = lambda *args, **kwargs: False
        bag = mlx_convert.load_mlx_model('htdemucs_6s', cache_dir=str(model_dir), auto_convert=False, verbose=False)
        members = list(bag.models) if hasattr(bag, 'models') else [bag]
        if len(members) != 1:
            raise ValueError('Expected one HTDemucs6 model')
        self.model = members[0]
        if list(self.model.sources) != SOURCES or self.model.samplerate != RATE:
            raise ValueError('Unexpected source or sample-rate contract')
        self.model.eval()
        self.model.segment = CONTEXT / RATE
        for _, module in self.model.named_modules():
            if isinstance(module, FastMultiHeadAttention):
                module.set_compute_dtype(mx.float32)
        mx.eval(self.model.parameters())
        mx.synchronize()
        if 'torch' in sys.modules:
            raise RuntimeError('Streaming runtime unexpectedly imported torch')
        self.np, self.mx, self.forward = np, mx, _forward
        self.crossfade = crossfade_frames
        self.context = np.zeros((CHANNELS, CONTEXT), dtype=np.float32)
        self.previous_tail = None
        self.skipped_silent_blocks = 0
        self.fade = np.linspace(0, 1, crossfade_frames, dtype=np.float32)[None, None, :] if crossfade_frames else None
        self.model_sha = config['safetensors_sha256']

    def reset(self):
        self.context.fill(0)
        self.previous_tail = None

    def estimate(self):
        np, mx = self.np, self.mx
        pcm = mx.array(self.context[None])
        start, end = CONTEXT - RIGHT - HOP, CONTEXT - RIGHT + self.crossfade
        predicted = self.forward(self.model, pcm, compile=True)[0, :, :, start:end]
        five = mx.stack([predicted[3], predicted[0], predicted[1], predicted[4], predicted[2] + predicted[5]])
        mx.eval(five)
        output = np.array(five).copy(order='C')
        mx.synchronize()
        if output.shape != (STEMS, CHANNELS, HOP + self.crossfade) or not np.isfinite(output).all():
            raise ValueError('Nonfinite or malformed model output')
        return output

    def warmup(self):
        durations = []
        for _ in range(3):
            began = time.perf_counter()
            self.estimate()
            durations.append(time.perf_counter() - began)
        self.reset()
        return durations

    def process(self, payload):
        np = self.np
        pcm = np.frombuffer(payload, dtype='<f4').reshape(HOP, CHANNELS).T
        if not np.isfinite(pcm).all():
            raise ValueError('Input contains nonfinite samples')
        self.context[:, :-HOP] = self.context[:, HOP:]
        self.context[:, -HOP:] = pcm
        if np.any(self.context):
            output = self.estimate()
        else:
            # Exactly-zero captured history has no sources. Keep the preceding
            # prediction tail's crossfade below; never threshold quiet program.
            output = np.zeros((STEMS, CHANNELS, HOP + self.crossfade), dtype=np.float32)
            self.skipped_silent_blocks += 1
        if self.crossfade:
            if self.previous_tail is not None:
                output[:, :, :self.crossfade] = self.previous_tail * (1 - self.fade) + output[:, :, :self.crossfade] * self.fade
            self.previous_tail = output[:, :, HOP:].copy()
        # Mixture consistency: keep the four named estimates intact and assign
        # their residual (including piano) to Other. At unity the five sources
        # reconstruct the original timestamp-aligned input, including seams.
        start = CONTEXT - RIGHT - HOP
        output[4, :, :HOP] = self.context[:, start:start + HOP] - output[:4, :, :HOP].sum(axis=0)
        return output[:, :, :HOP].transpose(0, 2, 1).astype('<f4', copy=False).tobytes(order='C')


class Service:
    def __init__(self, backend, source, destination, offline=False):
        self.backend, self.source, self.destination = backend, source, destination
        self.offline = offline
        self.mailbox = Mailbox()
        self.outbox = queue.Queue(MAX_OUTPUT_QUEUE)
        self.transport_failed = threading.Event()

    def emit(self, packet):
        try:
            self.outbox.put(packet, timeout=.25)
        except queue.Full:
            self.transport_failed.set()
            raise BrokenPipeError('Host is not draining output; bounded queue full')

    def writer(self):
        try:
            while True:
                packet = self.outbox.get()
                if packet is None:
                    return
                if packet.kind == OUTPUT and not self.mailbox.current(packet):
                    continue
                data = packet.encode()
                # FileIO and test transports can return partial writes.
                view = memoryview(data)
                while view:
                    written = self.destination.write(view)
                    if not written:
                        raise BrokenPipeError('Output closed')
                    view = view[written:]
                self.destination.flush()
        except (BrokenPipeError, OSError, ValueError) as error:
            print(json.dumps({'event': 'transport_error', 'message': str(error)}), file=sys.stderr)
            self.transport_failed.set()
            self.mailbox.accept(Packet(CLOSE))

    def reader(self):
        try:
            while True:
                packet = read_packet(self.source)
                if packet is None:
                    packet = Packet(CLOSE)
                for error in self.mailbox.accept(packet):
                    self.emit(error)
                if packet.kind == CLOSE:
                    return
        except (ProtocolError, OSError, BrokenPipeError) as error:
            with contextlib.suppress(BrokenPipeError):
                self.emit(error_packet('PROTOCOL', str(error), recoverable=False))
            self.mailbox.accept(Packet(CLOSE))

    def run(self, ready):
        writer = threading.Thread(target=self.writer, name='catstem-output', daemon=True)
        writer.start()
        self.emit(json_packet(READY, ready))
        reader = threading.Thread(target=self.reader, name='catstem-input', daemon=True)
        reader.start()
        processed = 0
        try:
            while not self.transport_failed.is_set():
                packet = self.mailbox.take()
                if packet is None or packet.kind == CLOSE:
                    self.emit(Packet(CLOSED, stream=self.mailbox.stream, generation=self.mailbox.generation))
                    break
                if not self.mailbox.current(packet):
                    continue
                if packet.kind == FLUSH:
                    self.backend.reset()
                    self.emit(replace(packet, kind=FLUSHED))
                    continue
                began = time.perf_counter()
                try:
                    output = self.backend.process(packet.payload)
                except (RuntimeError, ValueError) as error:
                    self.mailbox.invalidate(packet)
                    self.emit(error_packet('INFERENCE', str(error), packet))
                    continue
                completed = time.perf_counter()
                if not self.mailbox.current(packet):
                    continue
                elapsed = completed - packet.received
                if not self.offline and elapsed > COMPUTE_BUDGET:
                    self.mailbox.invalidate(packet)
                    self.emit(error_packet('DEADLINE', f'Output exceeded {COMPUTE_BUDGET * 1000:.2f} ms budget ({elapsed * 1000:.2f} ms); FLUSH required', packet))
                    continue
                self.emit(replace(packet, kind=OUTPUT, first_frame=packet.first_frame - RIGHT,
                                  channels=CHANNELS, stems=STEMS, payload=output))
                processed += 1
                if processed % 64 == 0:
                    print(json.dumps({'event': 'performance', 'blocks': processed,
                                      'computeSeconds': completed - began, 'workerSeconds': elapsed,
                                      'skippedSilentBlocks': getattr(self.backend, 'skipped_silent_blocks', 0)}), file=sys.stderr, flush=True)
        finally:
            with contextlib.suppress(queue.Full):
                self.outbox.put(None, timeout=.25)
            writer.join(timeout=1)
        return 1 if self.transport_failed.is_set() else 0


def capability(model_dir):
    supported = platform.system() == 'Darwin' and platform.machine() == 'arm64'
    try:
        supported = supported and int(platform.mac_ver()[0].split('.')[0]) >= 14
    except ValueError:
        supported = False
    required = ['mlx', 'demucs-mlx', 'numpy']
    versions = {}
    for name in required:
        try:
            versions[name] = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            supported = False
    files = all((model_dir / name).is_file() for name in ['htdemucs_6s.safetensors', 'htdemucs_6s_config.json'])
    return {'available': supported and files, 'platformSupported': supported, 'modelPresent': files,
            'backend': 'mlx-htdemucs6', 'minimumMacOS': 14, 'architecture': 'arm64',
            'versions': versions, 'modelDirectory': str(model_dir),
            'reason': '' if supported and files else 'Requires macOS 14+, Apple Silicon and the bundled MLX model/runtime'}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    default_model = Path(__file__).resolve().parents[1] / 'StemSeparationRuntime/realtime-arm64/models'
    p.add_argument('--model-dir', '--model-cache', type=Path, default=default_model)
    p.add_argument('--probe', action='store_true', help='JSON capability check; no model imports or inference')
    p.add_argument('--crossfade-frames', type=int, default=1024)
    p.add_argument('--offline', action='store_true', help='Explicit offline render only: retain bounded queues but omit wall-time deadline')
    args = p.parse_args()
    support = capability(args.model_dir)
    if args.probe:
        print(json.dumps(support))
        return 0 if support['available'] else 2
    destination = sys.stdout.buffer
    try:
        if not support['available']:
            raise RuntimeError(support['reason'])
        with contextlib.redirect_stdout(sys.stderr):
            backend = MLXBackend(args.model_dir, args.crossfade_frames)
            warmup = backend.warmup()
        ready = {'protocolVersion': VERSION, 'sampleRate': RATE, 'channels': CHANNELS, 'stems': STEMS,
                 'hopFrames': HOP, 'contextFrames': CONTEXT, 'rightContextFrames': RIGHT,
                 'latencyFrames': LATENCY, 'maxStreams': 1, 'maxQueuedAudio': MAX_INPUT_QUEUE,
                 'backend': 'mlx-htdemucs6', 'modelSHA': backend.model_sha, 'sourceCheckpointSHA': SOURCE_SHA,
                 'outputNames': OUTPUT_NAMES, 'crossfadeFrames': backend.crossfade,
                 'warmupSeconds': warmup, 'versions': support['versions'],
                 'offlineRendering': args.offline}
        return Service(backend, sys.stdin.buffer, destination, offline=args.offline).run(ready)
    except (RuntimeError, ValueError, OSError, ImportError) as error:
        print(json.dumps({'event': 'fatal', 'message': str(error)}), file=sys.stderr, flush=True)
        with contextlib.suppress(BrokenPipeError):
            destination.write(error_packet('BACKEND_UNAVAILABLE', str(error), recoverable=False).encode())
            destination.flush()
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
