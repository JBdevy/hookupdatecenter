#!/usr/bin/env python3
"""Test-only deterministic CST1 peer. Does not import or simulate an AI model."""
import argparse
import array
import json
from pathlib import Path
import struct
import sys
import time

HEADER = struct.Struct('<4sHHQQQqIIHHIII')
HOP, RIGHT = 8192, 3072
p = argparse.ArgumentParser()
p.add_argument('--model-cache', type=Path, required=True)
p.add_argument('--offline', action='store_true')
args = p.parse_args()
mode_file = args.model_cache / 'mode'
mode = mode_file.read_text().strip() if mode_file.exists() else 'identity'


def exact(count):
    data = bytearray()
    while len(data) < count:
        chunk = sys.stdin.buffer.read(count - len(data))
        if not chunk:
            raise EOFError()
        data.extend(chunk)
    return bytes(data)


def emit(kind, generation=0, sequence=0, first=0, pcm=b'', frames=0, stems=0):
    header = HEADER.pack(b'CST1', 1, kind, 1, generation, sequence, first, 44100, frames, 2, stems, len(pcm), 0, 0)
    sys.stdout.buffer.write(header + pcm)
    sys.stdout.buffer.flush()


ready = {'protocolVersion': 1, 'sampleRate': 44100, 'channels': 2, 'stems': 5,
         'hopFrames': HOP, 'contextFrames': 44100, 'rightContextFrames': RIGHT, 'latencyFrames': 24576,
         'maxStreams': 1, 'offlineRendering': args.offline,
         'outputNames': ['Vocal', 'Drum', 'Bass', 'Guitar', 'Other']}
if mode == 'bad_json_types':
    ready['sampleRate'] = []
if mode == 'fractional_metadata':
    ready['sampleRate'] = 44100.9
emit(1, pcm=json.dumps(ready).encode())
history = array.array('f', [0.0] * (RIGHT * 2))
last = None
try:
    while True:
        header = HEADER.unpack(exact(64))
        kind, generation, sequence, first, frames, size = header[2], header[4], header[5], header[6], header[8], header[11]
        payload = exact(size) if size else b''
        if kind == 4:
            if last:
                emit(3, *last)  # Deliberately deliver an old epoch across FLUSH.
            history = array.array('f', [0.0] * (RIGHT * 2))
            emit(5, generation)
        elif kind == 2:
            if mode == 'oversized':
                sys.stdout.buffer.write(HEADER.pack(b'CST1', 1, 3, 1, generation, sequence, first, 44100, HOP, 2, 5, 0xffffffff, 0, 0))
                sys.stdout.buffer.flush()
                time.sleep(30)
            if mode == 'stalled':
                sys.stdout.buffer.write(b'CST1')
                sys.stdout.buffer.flush()
                time.sleep(30)
            if mode == 'jitter':
                time.sleep(.160 if sequence % 3 == 1 else .060)
            pcm = array.array('f'); pcm.frombytes(payload)
            history.extend(pcm)
            block = history[:HOP * 2]
            del history[:HOP * 2]
            five = b''.join(array.array('f', (value * scale for value in block)).tobytes()
                            for scale in [.1, .2, .3, .15, .25])
            if mode == 'wrong_clock':
                first += 100
            last = (generation, sequence, first - RIGHT, five, HOP, 5)
            emit(3, *last)
        elif kind == 7:
            emit(8, generation)
            break
except (EOFError, BrokenPipeError):
    pass
