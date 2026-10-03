"""Synthetic Mach-O fixtures; run with python3 Tests/Apple/test_macos_deployment.py."""
import importlib.util
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/test-macos-deployment.py"
SPEC = importlib.util.spec_from_file_location("macos_deployment", SCRIPT)
deployment = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = deployment
SPEC.loader.exec_module(deployment)


def thin(cpu=0x0100000c, minimum=12 << 16, legacy=False, endian="<", platform=1):
    subtype = 3 if cpu == 0x01000007 else 0
    command = (struct.pack(endian + "4I", 0x24, 16, minimum, 0) if legacy else
               struct.pack(endian + "6I", 0x32, 24, platform, minimum, 0, 0))
    return struct.pack(endian + "8I", 0xfeedfacf, cpu, subtype, 2, 1, len(command), 0, 0) + command


def fat(*slices, wide=False, endian=">"):
    entry_size = 32 if wide else 20
    offset = 8 + len(slices) * entry_size
    result = struct.pack(endian + "2I", 0xcafebabf if wide else 0xcafebabe, len(slices))
    for data in slices:
        cpu, subtype = struct.unpack_from("<2I", data, 4)
        fields = [cpu, subtype, offset, len(data), 0] + ([0] if wide else [])
        result += struct.pack(endian + ("IIQQII" if wide else "IIIII"), *fields)
        offset += len(data)
    return result + b"".join(slices)


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def read(self, data):
        path = self.root / "binary"
        path.write_bytes(data)
        return deployment.read_macho(path)

    def app(self, data):
        app = self.root / "CatLive.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/MacOS/CatLive").write_bytes(data)
        with (app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleExecutable": "CatLive", "LSMinimumSystemVersion": "12.0"}, stream)
        return app

    def test_modern_and_legacy_versions_and_endianness(self):
        for legacy in (False, True):
            for endian in ("<", ">"):
                item = self.read(thin(minimum=(11 << 16) | (1 << 8), legacy=legacy, endian=endian))[0]
                self.assertEqual(item.minimum, (11, 1, 0))
                self.assertEqual(item.command, "LC_VERSION_MIN_MACOSX" if legacy else "LC_BUILD_VERSION")

    def test_universal32_and64_both_endiannesses(self):
        for wide in (False, True):
            for endian in ("<", ">"):
                slices = self.read(fat(thin(), thin(cpu=0x01000007, minimum=13 << 16), wide=wide, endian=endian))
                self.assertEqual([s.arch for s in slices], ["arm64", "x86_64"])
                self.assertEqual(slices[1].minimum, (13, 0, 0))

    def test_rejects_corruption_and_foreign_platform(self):
        for data in (thin()[:-1], thin(platform=2), thin()[:32], fat(thin())[:-1]):
            with self.assertRaises(deployment.InvalidMachO):
                self.read(data)
        self.assertIsNone(self.read(b"not a Mach-O"))

    def test_full_app_and_architecture_specific_runtime(self):
        app = self.app(fat(thin(), thin(cpu=0x01000007)))
        runtime = app / "Contents/Resources/runtime"
        runtime.mkdir(parents=True)
        binary = runtime / "python"
        binary.write_bytes(thin(minimum=11 << 16))
        (runtime / "python3").symlink_to("python")
        errors, binaries = deployment.audit(app, (12, 0, 0), {"arm64", "x86_64"})
        self.assertEqual(errors, [])
        self.assertEqual(len(binaries), 2)

    def test_checks_embedded_slice_and_main_architecture(self):
        app = self.app(thin())
        runtime = app / "Contents/Resources"
        runtime.mkdir()
        (runtime / "library.dylib").write_bytes(fat(thin(), thin(cpu=0x01000007, minimum=13 << 16)))
        errors, _ = deployment.audit(app, (12, 0, 0), {"arm64", "x86_64"})
        self.assertTrue(any("library.dylib [x86_64]" in error and "13.0" in error for error in errors))
        self.assertTrue(any("missing architectures: x86_64" in error for error in errors))

    def test_checks_plist_and_architecture_overrides(self):
        app = self.app(fat(thin(), thin(cpu=0x01000007)))
        with (app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleExecutable": "CatLive", "LSMinimumSystemVersion": "13.0",
                          "LSMinimumSystemVersionByArchitecture": {"x86_64": "14.0"}}, stream)
        errors, _ = deployment.audit(app, (12, 0, 0), {"arm64", "x86_64"})
        self.assertTrue(any("LSMinimumSystemVersion='13.0'" in error for error in errors))
        self.assertTrue(any("[x86_64]: requires macOS 14.0" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
