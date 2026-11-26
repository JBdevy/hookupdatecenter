#!/usr/bin/env python3
"""Deterministic CST1 fixture: protocol/host DSP test, never shipped as a model."""
import argparse
import importlib.util
from pathlib import Path
import struct
import sys
parser=argparse.ArgumentParser();parser.add_argument('--model',required=True);parser.add_argument('--offline',action='store_true');args=parser.parse_args()
# Fixture is next to the shared protocol when deployed by the test harness.
path=Path(__file__).with_name('stream.py')
spec=importlib.util.spec_from_file_location('identity_protocol',path);p=importlib.util.module_from_spec(spec);sys.modules[spec.name]=p;spec.loader.exec_module(p)
# Mirror the explicit Windows buffer without modifying the shared Mac module.
assert (p.HOP,p.LATENCY)==(8192,24576)
p.LATENCY=66150
p.COMPUTE_BUDGET=(p.LATENCY-p.HOP-p.RIGHT)/p.RATE
out=sys.stdout.buffer
ready=dict(protocolVersion=1,sampleRate=p.RATE,channels=2,stems=5,hopFrames=p.HOP,contextFrames=p.CONTEXT,rightContextFrames=p.RIGHT,latencyFrames=p.LATENCY,maxStreams=1,offlineRendering=args.offline,outputNames=p.OUTPUT_NAMES,sourceCheckpointSHA=p.SOURCE_SHA)
out.write(p.json_packet(p.READY,ready).encode());out.flush()
previous=bytes(p.RIGHT*8)
while True:
    packet=p.read_packet(sys.stdin.buffer)
    if packet is None:break
    if packet.kind==p.FLUSH:
        previous=bytes(p.RIGHT*8)
        out.write(p.Packet(p.FLUSHED,stream=packet.stream,generation=packet.generation).encode());out.flush()
    elif packet.kind==p.AUDIO:
        source=previous+packet.payload
        aligned=source[:p.HOP*8];previous=source[p.HOP*8:]
        samples=struct.unpack('<'+str(p.HOP*2)+'f',aligned)
        half=struct.pack('<'+str(p.HOP*2)+'f',*(v*.5 for v in samples))
        payload=half+bytes(p.HOP*8*3)+half
        response=p.Packet(p.OUTPUT,stream=packet.stream,generation=packet.generation,sequence=packet.sequence,first_frame=packet.first_frame-p.RIGHT,frames=p.HOP,channels=2,stems=5,payload=payload)
        out.write(response.encode());out.flush()
    else:break
