#!/usr/bin/env python3
"""Write the self-contained SF2 bank used by the native instrument tests.

The RIFF/Hydra layout follows Windows/Source/InstrumentRenderTests.h. The
sample is an integer triangle wave so the resulting bytes are identical on
Intel, Apple Silicon and Windows, without downloaded fonts or dependencies.
This is test data only; it does not modify the instrument catalog.
"""

import argparse
import struct
from pathlib import Path


def chunk(identifier, payload):
    assert len(identifier) == 4
    return identifier + struct.pack("<I", len(payload)) + payload + b"\0" * (len(payload) & 1)


def name(value):
    encoded = value.encode("ascii")
    assert len(encoded) < 20
    return encoded.ljust(20, b"\0")


def bank():
    # One 512-frame loop at 48 kHz, root key C4, followed by the 46 zero
    # guard samples required by SF2. All notes use this continuously looping
    # sample, allowing long envelope, sustain and MIDI-controller assertions.
    pcm = []
    for frame in range(512):
        distance = frame if frame < 128 else 256 - frame if frame < 384 else frame - 512
        pcm.append(distance * 12000 // 128)
    pcm.extend([0] * 46)
    samples = struct.pack("<" + "h" * len(pcm), *pcm)

    info = b"INFO"
    info += chunk(b"ifil", struct.pack("<HH", 2, 1))
    info += chunk(b"isng", b"EMU8000\0")
    info += chunk(b"INAM", b"CatLive generated test bank\0")

    # Each Hydra table ends with its required terminal record. Generator
    # indices point to the first generator of the following zone/terminal.
    phdr = name("Test tone") + struct.pack("<HHHIII", 0, 0, 0, 0, 0, 0)
    phdr += name("EOP") + struct.pack("<HHHIII", 0, 0, 1, 0, 0, 0)
    pbag = struct.pack("<HHHH", 0, 0, 1, 0)
    pmod = bytes(10)
    pgen = struct.pack("<HHHH", 41, 0, 0, 0)  # instrument 0, terminal
    inst = name("Test tone") + struct.pack("<H", 0)
    inst += name("EOI") + struct.pack("<H", 1)
    ibag = struct.pack("<HHHH", 0, 0, 3, 0)
    imod = bytes(10)
    igen = struct.pack("<HH", 43, 127 << 8)  # keyRange 0..127, including 42/44/46/60/67
    igen += struct.pack("<HH", 54, 1)  # sampleModes: loop throughout release
    igen += struct.pack("<HH", 53, 0)  # sampleID 0 must be the last zone generator
    igen += bytes(4)
    shdr = name("Test sample") + struct.pack("<IIIIIBbHH", 0, 512, 0, 512, 48000, 60, 0, 0, 1)
    shdr += name("EOS") + bytes(26)
    assert len(phdr) == 2 * 38 and len(inst) == 2 * 22 and len(shdr) == 2 * 46

    tables = [(b"phdr", phdr), (b"pbag", pbag), (b"pmod", pmod),
              (b"pgen", pgen), (b"inst", inst), (b"ibag", ibag),
              (b"imod", imod), (b"igen", igen), (b"shdr", shdr)]
    pdta = b"pdta" + b"".join(chunk(identifier, payload) for identifier, payload in tables)
    body = b"sfbk" + chunk(b"LIST", info)
    body += chunk(b"LIST", b"sdta" + chunk(b"smpl", samples))
    body += chunk(b"LIST", pdta)
    return chunk(b"RIFF", body)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="destination .sf2 file")
    output = parser.parse_args().output.expanduser()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(bank())
    print(output)


if __name__ == "__main__":
    main()
