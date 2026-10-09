#!/usr/bin/env python3
"""Drive the real CST1 worker with musical PCM and capture timing/seam diagnostics.

This test client may read/write WAV artifacts. The worker receives only framed
PCM. Use --offline for faster-than-wall-time quality capture; those timings
must not be presented as a paced realtime soak.
"""
import argparse
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time

sys.dont_write_bytecode = True
WORKER = Path(__file__).resolve().parents[2] / 'Apple/Resources/StemSeparation/stream.py'
spec = importlib.util.spec_from_file_location('catstem_stream', WORKER)
protocol = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = protocol
spec.loader.exec_module(protocol)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--python', type=Path, required=True)
    p.add_argument('--model-dir', type=Path, required=True)
    p.add_argument('--input', type=Path, required=True)
    p.add_argument('--seconds', type=float, default=60)
    p.add_argument('--crossfade-frames', type=int, default=1024)
    p.add_argument('--offline', action='store_true')
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    import numpy as np
    import soundfile as sf
    audio, rate = sf.read(args.input, dtype='float32', always_2d=True)
    if rate != protocol.RATE or audio.shape[1] != 2 or not np.isfinite(audio).all():
        raise ValueError('Fixture must be finite stereo44.1kHz')
    count = round(args.seconds * rate)
    audio = np.tile(audio, (math.ceil(count / len(audio)), 1))[:count]
    args.output.mkdir(parents=True, exist_ok=True)
    result_audio = np.zeros((5, count, 2), dtype=np.float32)
    coverage = np.zeros(count, dtype=np.uint8)
    def model_snapshot():
        snapshot = {}
        for name in ['htdemucs_6s.safetensors', 'htdemucs_6s_config.json']:
            path = args.model_dir / name
            with path.open('rb') as handle:
                digest = hashlib.file_digest(handle, 'sha256').hexdigest()
            snapshot[name] = {'sha256': digest, 'mtimeNS': path.stat().st_mtime_ns}
        snapshot['directoryEntries'] = sorted(path.name for path in args.model_dir.iterdir())
        return snapshot
    initial_models = model_snapshot()
    command = [str(args.python), '-I', '-B', str(WORKER), '--model-dir', str(args.model_dir),
               '--crossfade-frames', str(args.crossfade_frames)]
    if args.offline:
        command.append('--offline')
    stderr = (args.output / 'worker-stderr.jsonl').open('wb')
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr, bufsize=0)
    inbox = queue.Queue(8)
    def reader():
        try:
            while True:
                packet = protocol.read_packet(process.stdout)
                inbox.put(packet)
                if packet is None:
                    return
        except Exception as error:
            inbox.put(error)
    threading.Thread(target=reader, daemon=True).start()
    def receive(timeout=120):
        packet = inbox.get(timeout=timeout)
        if packet is None or isinstance(packet, Exception):
            raise RuntimeError(f'Worker ended: {packet}')
        if packet.kind == protocol.ERROR:
            raise RuntimeError(packet.payload.decode())
        return packet
    def send(packet):
        data = memoryview(packet.encode())
        while data:
            n = process.stdin.write(data)
            if not n:
                raise BrokenPipeError('Worker input closed')
            data = data[n:]
    report = {'command': command, 'offline': args.offline, 'input': str(args.input),
              'seconds': args.seconds, 'completed': False, 'blocks': []}
    report['modelsBefore'] = initial_models
    began = time.perf_counter()
    try:
        ready = receive()
        if ready.kind != protocol.READY:
            raise RuntimeError('Expected READY')
        report['ready'] = json.loads(ready.payload)
        report['startupSeconds'] = time.perf_counter() - began
        send(protocol.Packet(protocol.FLUSH, 1, 1))
        if receive().kind != protocol.FLUSHED:
            raise RuntimeError('Expected FLUSHED')
        epoch = time.perf_counter()
        blocks = math.ceil((count + protocol.RIGHT) / protocol.HOP)
        for sequence in range(blocks):
            first = sequence * protocol.HOP
            if not args.offline:
                remaining = epoch + sequence * protocol.HOP / rate - time.perf_counter()
                if remaining > 0:
                    time.sleep(remaining)
            block = np.zeros((protocol.HOP, 2), dtype='<f4')
            valid = max(0, min(protocol.HOP, count - first))
            if valid:
                block[:valid] = audio[first:first + valid]
            sent = time.perf_counter()
            send(protocol.Packet(protocol.AUDIO, 1, 1, sequence, first, rate,
                                 protocol.HOP, 2, 0, block.tobytes()))
            output = receive(timeout=30)
            arrived = time.perf_counter()
            if (output.kind, output.sequence, output.generation, output.first_frame,
                output.frames, output.channels, output.stems, len(output.payload)) != (
                    protocol.OUTPUT, sequence, 1, first - protocol.RIGHT, protocol.HOP, 2, 5,
                    protocol.HOP * 2 * 5 * 4):
                raise RuntimeError('Output framing/source clock mismatch')
            pcm = np.frombuffer(output.payload, dtype='<f4').reshape(5, protocol.HOP, 2)
            if not np.isfinite(pcm).all():
                raise RuntimeError('Output contains nonfinite PCM')
            lo, hi = max(0, output.first_frame), min(count, output.first_frame + protocol.HOP)
            if hi > lo:
                result_audio[:, lo:hi] = pcm[:, lo - output.first_frame:hi - output.first_frame]
                coverage[lo:hi] += 1
            report['blocks'].append({'sequence': sequence, 'responseSeconds': arrived - sent,
                                     'sendScheduleErrorSeconds': sent - (epoch + first / rate),
                                     'sourceFrame': output.first_frame})
            if sequence % 64 == 0:
                print(json.dumps({'event': 'progress', 'blocks': sequence + 1, 'totalBlocks': blocks}), flush=True)
        send(protocol.Packet(protocol.CLOSE, 1, 1))
        if receive(timeout=5).kind != protocol.CLOSED:
            raise RuntimeError('Expected CLOSED')
        process.wait(timeout=5)
        if process.returncode or not np.all(coverage == 1):
            raise RuntimeError('Process failed or source coverage has gaps/duplicates')
        elapsed = [b['responseSeconds'] for b in report['blocks']]
        report['timing'] = {'p50Seconds': float(np.percentile(elapsed, 50)),
                            'p95Seconds': float(np.percentile(elapsed, 95)),
                            'p99Seconds': float(np.percentile(elapsed, 99)), 'maxSeconds': max(elapsed),
                            'responsesOverComputeBudget': sum(t > protocol.COMPUTE_BUDGET for t in elapsed),
                            'computeBudgetSeconds': protocol.COMPUTE_BUDGET, 'blocks': len(elapsed), 'declaredLatencySeconds': protocol.LATENCY / rate}
        seams = np.arange(protocol.HOP - protocol.RIGHT, count, protocol.HOP)
        report['stems'] = {}
        for idx, name in enumerate(protocol.OUTPUT_NAMES):
            stem = result_audio[idx]
            derivative = np.abs(np.diff(stem, axis=0))
            jumps = np.abs(stem[seams] - stem[seams - 1])
            report['stems'][name] = {'rms': float(np.sqrt(np.mean(stem.astype(np.float64) ** 2))),
                                     'peak': float(np.max(np.abs(stem))),
                                     'seamJumpP95': float(np.percentile(jumps, 95)),
                                     'seamJumpMax': float(np.max(jumps)),
                                     'derivativeP95': float(np.percentile(derivative, 95))}
            sf.write(args.output / f'{name}.wav', stem, rate, subtype='FLOAT')
        remix = result_audio.sum(axis=0)
        error = remix.astype(np.float64) - audio
        report['unityRemixSNRdB'] = float(10 * np.log10(np.sum(audio.astype(np.float64) ** 2) / max(float(np.sum(error ** 2)), 1e-30)))
        report['qualityCaveat'] = 'No ground-truth SDR or listening verdict; seam metrics are descriptive and need matched A/B.'
        sf.write(args.output / 'input.wav', audio, rate, subtype='FLOAT')
        sf.write(args.output / 'remix.wav', remix, rate, subtype='FLOAT')
        report['completed'] = True
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        stderr.close()
        report['modelsAfter'] = model_snapshot()
        report['modelContentsAndMtimeUnchanged'] = report['modelsBefore'] == report['modelsAfter']
        (args.output / 'report.json').write_text(json.dumps(report, indent=2))
    print(json.dumps({'event': 'complete', 'report': str(args.output / 'report.json'),
                      'timing': report['timing'], 'unityRemixSNRdB': report['unityRemixSNRdB']}), flush=True)


if __name__ == '__main__':
    main()
