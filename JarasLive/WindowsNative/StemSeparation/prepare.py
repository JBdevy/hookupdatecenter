#!/usr/bin/env python3
"""Prepare an isolated Windows CPU validation runtime. Never installs globally."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

PYTHON_URL = 'https://github.com/astral-sh/python-build-standalone/releases/download/20250521/cpython-3.11.12%2B20250521-x86_64-pc-windows-msvc-install_only_stripped.tar.gz'
PYTHON_SHA = '405744f427e40139bf11dd81c342e6dcb253e82a6a6e1ac3b984f31bcf6aae64'
MODEL_NAME = '5c90dfd2-34c22ccb.th'
MODEL_SHA = '34c22ccb381c6f9fdbf324f04e1e2fe21aaaf293f5ded163a162697ff9a02ddd'


def download(url, destination, digest):
    with urllib.request.urlopen(url, timeout=60) as source, destination.open('wb') as target:
        shutil.copyfileobj(source, target)
    with destination.open('rb') as source:
        if hashlib.file_digest(source, 'sha256').hexdigest() != digest:
            raise RuntimeError('Download SHA256 mismatch: ' + destination.name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if platform.system() != 'Windows' or platform.machine().lower() not in ('amd64', 'x86_64'):
        raise RuntimeError('This runtime preparation requires Windows x64')
    target = args.output.resolve()
    if target.exists():
        raise RuntimeError('Use a new runtime directory; existing runtimes are not overwritten')
    target.parent.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(target.parent).free < 2 * 1024**3:
        raise RuntimeError('At least 2 GB of free build space is required')
    root = Path(__file__).resolve().parents[2]
    lock = Path(__file__).with_name('requirements.lock')
    with tempfile.TemporaryDirectory(prefix='catstem-', dir=target.parent) as temporary:
        staging = Path(temporary)
        archive = staging / 'python.tar.gz'
        download(PYTHON_URL, archive, PYTHON_SHA)
        with tarfile.open(archive) as package:
            package.extractall(staging, filter='data')
        archive.unlink()
        python = staging / 'python/python.exe'
        subprocess.run([str(python), '-m', 'pip', 'install', '--no-cache-dir', '-r', str(lock)], check=True)
        download('https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/' + MODEL_NAME, staging / MODEL_NAME, MODEL_SHA)
        shutil.copy2(root / 'Apple/Resources/StemSeparation/stream.py', staging / 'stream.py')
        shutil.copy2(Path(__file__).with_name('stream_windows.py'), staging / 'stream_windows.py')
        subprocess.run([str(python), '-I', '-c', 'import torch, demucs, numpy; print(torch.__version__)'], check=True)
        manifest = {'pythonSHA256': PYTHON_SHA, 'modelSHA256': MODEL_SHA,
                    'requirementsSHA256': hashlib.sha256(lock.read_bytes()).hexdigest(),
                    'backend': 'torch-htdemucs6', 'architecture': 'windows-x64',
                    'status': 'validation runtime; not yet integrated with the CatLive Windows audio graph'}
        (staging / 'runtime.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
        shutil.copytree(staging, target)
    print('CatStem validation runtime prepared:', target)


if __name__ == '__main__':
    main()
