"""Packaging tests that do not inherit MSVC DLLs from the developer's Windows."""
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('catstem_prepare', Path(__file__).with_name('prepare.py'))
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


def dll(path, machine=0x8664):
    path.parent.mkdir(parents=True, exist_ok=True)
    data = bytearray(70)
    data[:2] = b'MZ'
    struct.pack_into('<I', data, 60, 64)
    data[64:68] = b'PE\0\0'
    struct.pack_into('<H', data, 68, machine)
    path.write_bytes(data)


class NativeRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='CatStem build with spaces ')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.redist = self.root / 'VC/Redist/MSVC/14.44.35211'
        self.crt = self.redist / 'x64/Microsoft.VC143.CRT'
        self.openmp = self.redist / 'x64/Microsoft.VC143.OpenMP'
        for name in prepare.VC_RUNTIME_FILES:
            dll((self.openmp if name == 'vcomp140.dll' else self.crt) / name)

    def test_bundles_matching_x64_crt_and_openmp_beside_interpreter(self):
        target = self.root / 'Application package/StemSeparationRuntime'
        prepare.bundle_visual_cpp_runtime(target, [self.root / 'VC/Redist/MSVC'])
        prepare.verify_native_runtime(target)
        for name in prepare.VC_RUNTIME_FILES:
            self.assertTrue((target / 'python' / name).is_file())

    def test_missing_openmp_cannot_pass_using_system_or_developer_dlls(self):
        (self.openmp / 'vcomp140.dll').unlink()
        with self.assertRaisesRegex(RuntimeError, 'OpenMP redistributable'):
            prepare.bundle_visual_cpp_runtime(self.root / 'package', [self.redist])

    def test_wrong_architecture_cannot_enter_x64_package(self):
        dll(self.openmp / 'vcomp140.dll', machine=0x14c)
        with self.assertRaisesRegex(RuntimeError, 'requires x64'):
            prepare.bundle_visual_cpp_runtime(self.root / 'package', [self.redist])

    def test_packaged_dependency_is_required_even_if_system_has_it(self):
        target = self.root / 'package'
        prepare.bundle_visual_cpp_runtime(target, [self.redist])
        (target / 'python/vcomp140.dll').unlink()
        with self.assertRaisesRegex(RuntimeError, 'Missing bundled Windows dependency: python/vcomp140.dll'):
            prepare.verify_native_runtime(target)



if __name__ == '__main__':
    unittest.main(verbosity=2)
