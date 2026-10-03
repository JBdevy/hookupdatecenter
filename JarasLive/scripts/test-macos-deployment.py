#!/usr/bin/env python3
"""Check an app's declared deployment target and every embedded Mach-O slice.

Usage: python3 scripts/test-macos-deployment.py /path/to/CatLive.app --minimum 12.0
This reads headers only; it never modifies binaries or their signatures. It checks
deployment metadata, not runtime API availability or external system libraries.
"""
from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass
import os
from pathlib import Path
import plistlib
import struct
import sys
from typing import BinaryIO


THIN = {
    b"\xce\xfa\xed\xfe": ("<", 28), b"\xcf\xfa\xed\xfe": ("<", 32),
    b"\xfe\xed\xfa\xce": (">", 28), b"\xfe\xed\xfa\xcf": (">", 32),
}
FAT = {
    b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
    b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True),
}
VERSION_COMMANDS = {0x24: "LC_VERSION_MIN_MACOSX", 0x32: "LC_BUILD_VERSION"}


class InvalidMachO(ValueError):
    pass


def version(text: str) -> tuple[int, int, int]:
    parts = text.split(".")
    if not 1 <= len(parts) <= 3 or any(not p.isdigit() for p in parts):
        raise ValueError(f"invalid macOS version: {text!r}")
    return tuple(int(p) for p in parts) + (0,) * (3 - len(parts))


def packed_version(value: int) -> tuple[int, int, int]:
    return value >> 16, (value >> 8) & 255, value & 255


def version_text(value: tuple[int, int, int]) -> str:
    return ".".join(str(p) for p in (value if value[2] else value[:2]))


def architecture(cpu: int, subtype: int) -> str:
    base = subtype & 0x00ffffff
    if cpu == 0x0100000c:
        return "arm64e" if base == 2 else "arm64"
    if cpu == 0x01000007:
        return "x86_64h" if base == 8 else "x86_64"
    return {7: "i386", 12: "arm", 18: "ppc", 0x01000012: "ppc64"}.get(cpu, f"cpu_{cpu:#x}")


@dataclass(frozen=True)
class Slice:
    cpu: int
    subtype: int
    minimum: tuple[int, int, int]
    command: str

    @property
    def arch(self) -> str:
        return architecture(self.cpu, self.subtype)


def read_at(stream: BinaryIO, offset: int, size: int, limit: int) -> bytes:
    if offset < 0 or size < 0 or offset + size > limit:
        raise InvalidMachO("header or load command lies outside its slice")
    stream.seek(offset)
    result = stream.read(size)
    if len(result) != size:
        raise InvalidMachO("truncated Mach-O")
    return result


def read_slice(stream: BinaryIO, offset: int, size: int) -> Slice:
    end = offset + size
    magic = read_at(stream, offset, 4, end)
    if magic not in THIN:
        raise InvalidMachO("universal binary contains a non-Mach-O slice")
    endian, header_size = THIN[magic]
    header = read_at(stream, offset, header_size, end)
    cpu, subtype, _, count, command_bytes, _ = struct.unpack_from(endian + "6I", header, 4)
    if command_bytes > 64 * 1024 * 1024 or count > command_bytes // 8:
        raise InvalidMachO("invalid load-command count or size")
    commands = read_at(stream, offset + header_size, command_bytes, end)
    cursor = 0
    deployments = []
    for _ in range(count):
        if cursor + 8 > len(commands):
            raise InvalidMachO("truncated load-command header")
        command, length = struct.unpack_from(endian + "2I", commands, cursor)
        if length < 8 or length % 4 or cursor + length > len(commands):
            raise InvalidMachO("invalid load-command length")
        if command == 0x32:
            if length < 24:
                raise InvalidMachO("truncated LC_BUILD_VERSION")
            platform, minimum, _, tools = struct.unpack_from(endian + "4I", commands, cursor + 8)
            if platform != 1:
                raise InvalidMachO(f"LC_BUILD_VERSION platform {platform} is not macOS")
            if 24 + tools * 8 > length:
                raise InvalidMachO("truncated LC_BUILD_VERSION tools")
            deployments.append((packed_version(minimum), VERSION_COMMANDS[command]))
        elif command == 0x24:
            if length < 16:
                raise InvalidMachO("truncated LC_VERSION_MIN_MACOSX")
            minimum = struct.unpack_from(endian + "I", commands, cursor + 8)[0]
            deployments.append((packed_version(minimum), VERSION_COMMANDS[command]))
        elif command in (0x25, 0x2f, 0x30):
            raise InvalidMachO("deployment command targets iOS, tvOS or watchOS")
        cursor += length
    if cursor != len(commands):
        raise InvalidMachO("load-command size does not match header")
    if not deployments:
        raise InvalidMachO("missing macOS deployment load command")
    minimum, command = max(deployments)
    if minimum[0] == 0:
        raise InvalidMachO("invalid zero deployment target")
    return Slice(cpu, subtype, minimum, command)


def read_macho(path: Path) -> list[Slice] | None:
    with path.open("rb") as stream:
        size = os.fstat(stream.fileno()).st_size
        magic = stream.read(4)
        if magic in THIN:
            return [read_slice(stream, 0, size)]
        if magic not in FAT:
            return None
        endian, is64 = FAT[magic]
        count = struct.unpack(endian + "I", read_at(stream, 4, 4, size))[0]
        if not 1 <= count <= 128:
            raise InvalidMachO("invalid universal architecture count")
        entry_size = 32 if is64 else 20
        table_end = 8 + count * entry_size
        table = read_at(stream, 8, count * entry_size, size)
        ranges = []
        slices = []
        for index in range(count):
            fields = struct.unpack_from(endian + ("IIQQII" if is64 else "IIIII"), table, index * entry_size)
            cpu, subtype, offset, length = fields[:4]
            if offset < table_end or length < 4 or offset + length > size:
                raise InvalidMachO("universal slice lies outside file")
            if any(offset < old_end and offset + length > old_start for old_start, old_end in ranges):
                raise InvalidMachO("overlapping universal slices")
            ranges.append((offset, offset + length))
            item = read_slice(stream, offset, length)
            if item.cpu != cpu or item.subtype != subtype:
                raise InvalidMachO("universal architecture differs from slice header")
            slices.append(item)
        if len({(s.cpu, s.subtype) for s in slices}) != len(slices):
            raise InvalidMachO("duplicate universal architecture")
        return slices


def audit(app: Path, minimum: tuple[int, int, int], required: set[str]) -> tuple[list[str], dict[Path, list[Slice]]]:
    app = app.resolve(strict=True)
    errors = []
    binaries = {}
    info_path = app / "Contents/Info.plist"
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    executable_name = info.get("CFBundleExecutable")
    if not isinstance(executable_name, str) or Path(executable_name).name != executable_name:
        raise ValueError("Info.plist has no valid CFBundleExecutable")
    executable = (app / "Contents/MacOS" / executable_name).resolve()
    seen = set()
    for directory, directories, filenames in os.walk(app):
        directories.sort()
        for name in sorted(filenames):
            path = Path(directory) / name
            if not path.is_file():
                continue
            resolved = path.resolve()
            if resolved in seen:
                continue
            seen.add(resolved)
            relative = path.relative_to(app)
            try:
                slices = read_macho(path)
                if slices is not None:
                    if not resolved.is_relative_to(app):
                        errors.append(f"{relative}: Mach-O symlink resolves outside the app")
                    binaries[resolved] = slices
                    for item in slices:
                        if item.minimum > minimum:
                            errors.append(f"{relative} [{item.arch}]: {item.command} requires macOS {version_text(item.minimum)}")
                if name == "Info.plist":
                    with path.open("rb") as stream:
                        metadata = plistlib.load(stream)
                    declared = metadata.get("LSMinimumSystemVersion")
                    if resolved == info_path.resolve():
                        if not isinstance(declared, str) or version(declared) != minimum:
                            errors.append(f"{relative}: LSMinimumSystemVersion={declared!r}, expected {version_text(minimum)}")
                    elif declared is not None and version(declared) > minimum:
                        errors.append(f"{relative}: requires macOS {declared}")
                    for arch, value in metadata.get("LSMinimumSystemVersionByArchitecture", {}).items():
                        if version(value) > minimum:
                            errors.append(f"{relative} [{arch}]: requires macOS {value}")
            except (OSError, ValueError, struct.error, plistlib.InvalidFileException) as error:
                errors.append(f"{relative}: {error}")
    main_slices = binaries.get(executable)
    if main_slices is None:
        errors.append(f"main executable is missing or is not a valid Mach-O: {executable_name}")
    else:
        missing = required - {item.arch for item in main_slices}
        if missing:
            errors.append("main executable missing architectures: " + ", ".join(sorted(missing)))
    return errors, binaries


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--minimum", default="12.0", help="exact app minimum and maximum embedded deployment target (default: 12.0)")
    parser.add_argument("--architectures", nargs="+", default=["arm64", "x86_64"], help="required main executable slices")
    args = parser.parse_args()
    try:
        minimum = version(args.minimum)
        errors, binaries = audit(args.app, minimum, set(args.architectures))
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    counts = Counter(item.arch for slices in binaries.values() for item in slices)
    print(f"Read {len(binaries)} Mach-O files ({sum(counts.values())} architecture slices).")
    for arch in sorted(counts):
        highest = max(item.minimum for slices in binaries.values() for item in slices if item.arch == arch)
        print(f"  {arch}: {counts[arch]} slices; highest minimum macOS {version_text(highest)}")
    for error in errors:
        print(f"FAIL: {error}", file=sys.stderr)
    if errors:
        return 1
    print(f"PASS: Info.plist, executable architectures and all embedded Mach-O deployment targets support macOS {version_text(minimum)}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
