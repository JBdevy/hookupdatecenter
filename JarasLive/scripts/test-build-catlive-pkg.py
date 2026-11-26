#!/usr/bin/env python3
"""Installer staging isolation and real macOS signed-payload round trip."""

import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('build_pkg', Path(__file__).with_name('build-catlive-pkg.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PackageTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='catlive-package-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.app = self.root / 'CatLive.app'
        self.contents = self.app / 'Contents'
        self.resources = self.contents / 'Resources'
        self.resources.mkdir(parents=True)
        self.executable = self.contents / 'MacOS/CatLive'
        self.executable.parent.mkdir()
        self.executable.write_bytes(b'#!/bin/sh\nexit 0\n')
        self.executable.chmod(0o755)
        (self.contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'com.catlive.installer-fixture',
            'CFBundleExecutable': 'CatLive', 'CFBundleName': 'CatLive',
            'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
            'CFBundleShortVersionString': '1.25',
        }))
        # The affected Torch headers had exactly 163 bytes. AppleDouble records
        # of that size can be mistaken for their hard-linked file on extraction.
        self.headers = []
        for arch in ('arm64', 'x86_64'):
            for relative in ('torch/csrc/Types.h', 'torch/csrc/jit/passes/batch_mm.h'):
                header = self.resources / arch / relative
                header.parent.mkdir(parents=True, exist_ok=True)
                header.write_bytes(b'// CatLive package resource\n'.ljust(163, b' '))
                self.headers.append(header)
        (self.resources / 'current.h').symlink_to('arm64/torch/csrc/Types.h')
        self.destination = self.root / 'CatLive.pkg'

    def test_staging_has_independent_inodes_and_preserves_source(self):
        analyzed = []
        original = self.headers[0].read_bytes()

        def run(command, **kwargs):
            if '--analyze' in command:
                payload = Path(command[command.index('--root') + 1]) / self.app.name
                for source in self.app.rglob('*'):
                    target = payload / source.relative_to(self.app)
                    if source.is_symlink():
                        self.assertTrue(target.is_symlink())
                        self.assertEqual(os.readlink(source), os.readlink(target))
                    elif source.is_file():
                        self.assertFalse(os.path.samefile(source, target), str(source))
                        self.assertEqual(source.read_bytes(), target.read_bytes())
                target = payload / self.headers[0].relative_to(self.app)
                target.write_bytes(b'staging must not modify the signed source')
                self.assertEqual(self.headers[0].read_bytes(), original)
                target.write_bytes(original)
                Path(command[-1]).write_bytes(plistlib.dumps([{'RootRelativeBundlePath': self.app.name}]))
                analyzed.append(payload)
            elif '--component-plist' in command:
                components = plistlib.loads(Path(command[command.index('--component-plist') + 1]).read_bytes())
                self.assertFalse(components[0]['BundleIsRelocatable'])
            elif '--synthesize' in command:
                Path(command[-1]).write_text('<installer-gui-script/>', encoding='utf-8')
            return subprocess.CompletedProcess(command, 0)

        with patch.object(module.subprocess, 'run', side_effect=run):
            module.build_package(self.app, self.destination, '1.25')
        self.assertEqual(len(analyzed), 1)
        self.assertEqual(self.headers[0].read_bytes(), original)

    @unittest.skipUnless(sys.platform == 'darwin' and all(Path(tool).exists() for tool in (
        '/usr/bin/pkgbuild', '/usr/bin/productbuild', '/usr/sbin/pkgutil', '/usr/bin/codesign', '/usr/bin/xattr',
    )), 'requires macOS packaging and signing tools')
    def test_real_package_round_trip_preserves_signed_resources(self):
        # Ad hoc signing requires no developer identity or network. Resource
        # attributes exercise Apple's metadata handling, not merely byte copies.
        # Do not copy the system executable's SIP/restricted file flags.
        shutil.copyfile('/usr/bin/true', self.executable)
        subprocess.run(['/usr/bin/xattr', '-w', 'com.catlive.packaging-test', 'fixture', str(self.headers[0])], check=True)
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', str(self.app)], check=True)
        module.build_package(self.app, self.destination, '1.25')
        expanded = self.root / 'expanded'
        subprocess.run(['/usr/sbin/pkgutil', '--expand-full', str(self.destination), str(expanded)], check=True)
        payloads = list(expanded.glob('*.pkg/Payload/CatLive.app'))
        self.assertEqual(len(payloads), 1)
        actual = payloads[0]
        expected_files = {str(path.relative_to(self.app)) for path in self.app.rglob('*') if path.is_file() or path.is_symlink()}
        actual_files = {str(path.relative_to(actual)) for path in actual.rglob('*') if path.is_file() or path.is_symlink()}
        self.assertEqual(actual_files, expected_files)
        self.assertFalse(list(actual.rglob('._*')))
        for relative in expected_files:
            source, target = self.app / relative, actual / relative
            if source.is_symlink():
                self.assertTrue(target.is_symlink())
                self.assertEqual(os.readlink(source), os.readlink(target))
            else:
                self.assertEqual(source.read_bytes(), target.read_bytes(), relative)
        for app in (self.app, actual):
            subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)


if __name__ == '__main__':
    unittest.main()
