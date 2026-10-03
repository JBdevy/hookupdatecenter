#!/usr/bin/env python3
"""Build-time, isolated CatStem runtime. End users need no Python or network.
Run on either Mac architecture before the macOS Xcode build. Nothing is installed
into the user's Python environment. Downloads are pinned and checked before use.
"""
import hashlib
import json
import importlib.metadata as metadata
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
TARGET = ROOT / 'build/StemSeparationRuntime'
MODEL = '5c90dfd2-34c22ccb.th'
MODEL_HASH = '34c22ccb381c6f9fdbf324f04e1e2fe21aaaf293f5ded163a162697ff9a02ddd'
HASHES = {'arm64': '6efe6025281ebba088d3950959f492483baa786542d71c8f9a36cdc23ea77bd6',
          'x86_64': '1d955360d8454e05d1dc3ce7aef6106505861d701c6acc164fa302bcdacd61ac'}


def download(url, path, digest):
    subprocess.run(['/usr/bin/curl', '-fL', '--retry', '3', '--connect-timeout', '30', '-o', str(path), url], check=True)
    if hashlib.sha256(path.read_bytes()).hexdigest() != digest:
        raise RuntimeError('Download checksum mismatch: ' + path.name)


def main():
    arch = platform.machine()
    if platform.system() != 'Darwin' or arch not in HASHES:
        raise RuntimeError('Build this runtime on an Apple Silicon or Intel Mac.')
    lock = ROOT / 'scripts/catstem-requirements.lock'
    manifest = dict(version=2, architectures=["arm64", "x86_64"], requirements=hashlib.sha256(lock.read_bytes()).hexdigest(), model=MODEL_HASH)
    marker = TARGET / 'runtime.json'
    if marker.exists() and json.loads(marker.read_text()) == manifest:
        print('CatStem runtime already prepared:', TARGET)
        return
    TARGET.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='catstem-build-', dir=TARGET.parent) as temp:
        staging = Path(temp)
        triple = 'aarch64' if arch == 'arm64' else 'x86_64'
        archive = staging / 'python.tar.gz'
        download('https://github.com/astral-sh/python-build-standalone/releases/download/20250521/'
                 f'cpython-3.11.12%2B20250521-{triple}-apple-darwin-install_only_stripped.tar.gz', archive, HASHES[arch])
        # Archive is the hash-pinned official relocatable CPython distribution.
        with tarfile.open(archive) as package:
            package.extractall(staging)
        archive.unlink()
        python = staging / 'python/bin/python3.11'
        subprocess.run([str(python), '-m', 'pip', 'install', '--no-cache-dir', '-r', str(lock)], check=True)
        download('https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/' + MODEL, staging / MODEL, MODEL_HASH)
        subprocess.run([str(python), '-I', '-c', 'import torch, demucs, soundfile; print(torch.__version__)'], check=True)
        # A universal CatLive includes a matching helper for both architectures.
        other = 'x86_64' if arch == 'arm64' else 'arm64'
        cross = staging / other
        cross.mkdir()
        triple = 'aarch64' if other == 'arm64' else 'x86_64'
        archive = cross / 'python.tar.gz'
        download('https://github.com/astral-sh/python-build-standalone/releases/download/20250521/'
                 f'cpython-3.11.12%2B20250521-{triple}-apple-darwin-install_only_stripped.tar.gz', archive, HASHES[other])
        with tarfile.open(archive) as package:
            package.extractall(cross)
        archive.unlink()
        native_site = staging / 'python/lib/python3.11/site-packages'
        cross_site = cross / 'python/lib/python3.11/site-packages'
        shutil.copytree(native_site, cross_site, dirs_exist_ok=True)
        binary = [d.metadata['Name'] + '==' + d.version for d in metadata.distributions(path=[str(native_site)])
                  if any(str(p).endswith(('.so', '.dylib')) for p in (d.files or []))]
        platforms = ['macosx_11_0_arm64', 'macosx_11_0_universal2'] if other == 'arm64' else [
            'macosx_10_9_x86_64', 'macosx_10_15_x86_64', 'macosx_11_0_x86_64',
            'macosx_10_9_universal2', 'macosx_11_0_universal2']
        platform_args = [arg for value in platforms for arg in ['--platform', value]]
        subprocess.run([str(python), '-m', 'pip', 'install', '--upgrade', '--no-compile', '--no-deps',
                        '--only-binary=:all:', *platform_args, '--target', str(cross_site), *binary], check=True)
        for path in (cross / 'python').rglob('*'):
            if path.is_symlink() or not path.is_file(): continue
            with path.open('rb') as source: magic = source.read(4)
            if magic in [b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe']:
                architectures = subprocess.check_output(['/usr/bin/lipo', '-archs', str(path)], text=True)
                if other not in architectures: raise RuntimeError('Wrong architecture: ' + str(path))
        (staging / arch).mkdir()
        (staging / 'python').rename(staging / arch / 'python')
        for cache in staging.rglob('__pycache__'):
            shutil.rmtree(cache)
        (staging / 'runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')
        # Keep package dist-info and CPython licenses with the shipped runtime.
        if TARGET.exists():
            shutil.rmtree(TARGET)
        shutil.copytree(staging, TARGET, symlinks=True)
    print('CatStem runtime ready:', TARGET)


if __name__ == '__main__':
    main()
