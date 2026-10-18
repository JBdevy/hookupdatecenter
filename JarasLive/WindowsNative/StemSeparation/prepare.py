#!/usr/bin/env python3
"""Build the isolated, redistributable CatStem Windows runtime; never installs globally."""
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
IR_FILES = ('htdemucs6-openvino.xml', 'htdemucs6-openvino.bin', 'htdemucs6-openvino.json')
WORKERS = ('stream.py', 'stream_windows.py', 'openvino_backend.py')


def digest(path):
    with Path(path).open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def download(url, destination, expected):
    with urllib.request.urlopen(url, timeout=60) as source, destination.open('wb') as target:
        shutil.copyfileobj(source, target)
    if digest(destination) != expected:
        raise RuntimeError('Download SHA256 mismatch: ' + destination.name)


def runtime_identity(lock):
    return {'pythonSHA256': PYTHON_SHA, 'modelSHA256': MODEL_SHA,
            'requirementsSHA256': digest(lock), 'backend': 'openvino-htdemucs6-split-fp32',
            'fallbackBackend': 'torch-htdemucs6', 'architecture': 'windows-x64',
            'protocol': 'CST1', 'runtimeVersion': 2, 'sampleRate': 44100,
            'contextFrames': 44100, 'rightContextFrames': 3072,
            'hopFrames': 22050, 'latencyFrames': 66150,
            'outputNames': ['Vocal', 'Drum', 'Bass', 'Guitar', 'Other']}


def verify_dependencies(target, lock):
    """Check the actual isolated interpreter; a cached JSON alone is insufficient."""
    python = target / 'python/python.exe'
    if not python.is_file() or digest(target / MODEL_NAME) != MODEL_SHA:
        raise RuntimeError('The CatStem interpreter or pinned checkpoint is missing/invalid.')
    script = '''import importlib.metadata as metadata, pathlib, sys
if sys.version_info[:3] != (3, 11, 12):
    raise RuntimeError('Unexpected CatStem Python version')
for line in pathlib.Path(sys.argv[1]).read_text(encoding='utf-8').splitlines():
    if '==' not in line: continue
    name, expected = line.split('==')
    actual = metadata.version(name)
    if actual != expected: raise RuntimeError(f'{name}: expected {expected}, got {actual}')
'''
    subprocess.run([str(python), '-I', '-B', '-c', script, str(lock)], check=True)


def verify_ir(target):
    subprocess.run([str(target / 'python/python.exe'), '-I', '-B',
                    str(target / 'openvino_backend.py'), '--model', str(target / MODEL_NAME),
                    '--output', str(target), '--verify'], check=True, stdout=subprocess.DEVNULL)


def verify_runtime(target, lock):
    target, lock = Path(target), Path(lock)
    manifest = json.loads((target / 'runtime.json').read_text(encoding='utf-8'))
    if any(manifest.get(key) != value for key, value in runtime_identity(lock).items()):
        raise RuntimeError('The cached CatStem runtime uses an incompatible pinned configuration.')
    for name in WORKERS + IR_FILES:
        if digest(target / name) != manifest.get('filesSHA256', {}).get(name):
            raise RuntimeError('CatStem runtime file SHA256 mismatch: ' + name)
    licenses = target / 'Licenses'
    for name in ('Demucs-LICENSE.txt', 'Python-LICENSE.txt', 'NOTICE.txt', 'requirements.lock'):
        if not (licenses / name).is_file():
            raise RuntimeError('CatStem redistribution notice is missing: ' + name)
    if digest(licenses / 'requirements.lock') != digest(lock):
        raise RuntimeError('The bundled CatStem dependency list differs from the pinned list.')
    verify_dependencies(target, lock)
    verify_ir(target)  # Verifies FP32 IR/model identity and hashes; no inference compilation.
    return manifest


def refresh_runtime(target, root, lock):
    """Refresh code/notices and verified IR after dependencies have been prepared."""
    target, root, lock = Path(target), Path(root), Path(lock)
    verify_dependencies(target, lock)
    scripts = root / 'WindowsNative/StemSeparation'
    shutil.copy2(root / 'Apple/Resources/StemSeparation/stream.py', target / 'stream.py')
    for name in WORKERS[1:]:
        shutil.copy2(scripts / name, target / name)
    if not all((target / name).is_file() for name in IR_FILES):
        # CPU conversion includes independent FP32 comparisons against the exact
        # eager checkpoint. Deployment never needs a model download or converter.
        subprocess.run([str(target / 'python/python.exe'), '-I', '-B',
                        str(target / 'openvino_backend.py'), '--model', str(target / MODEL_NAME),
                        '--output', str(target)], check=True)
    verify_ir(target)
    licenses = target / 'Licenses'
    licenses.mkdir(exist_ok=True)
    shutil.copy2(root / 'Apple/Resources/StemSeparation/Demucs-LICENSE.txt', licenses / 'Demucs-LICENSE.txt')
    shutil.copy2(target / 'python/LICENSE.txt', licenses / 'Python-LICENSE.txt')
    shutil.copy2(lock, licenses / 'requirements.lock')
    # Every wheel retains its notices in situ, and these copies make them visible
    # beside the app's other notices, including OpenVINO's bundled components.
    for metadata in (target / 'python/Lib/site-packages').glob('*.dist-info'):
        for notice in metadata.rglob('*'):
            if notice.is_file() and any(word in notice.name.lower() for word in ('license', 'licence', 'copying', 'notice')):
                dest = licenses / metadata.name / notice.relative_to(metadata)
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(notice, dest)
    (licenses / 'NOTICE.txt').write_text('CatStemSeparation 5 Windows\n'
        'HTDemucs6 / Demucs 4.0.1, Meta Platforms, MIT license.\n'
        'https://github.com/facebookresearch/demucs\n'
        'Weights: 5c90dfd2-34c22ccb.th; SHA256 ' + MODEL_SHA + '\n'
        'Same six-source checkpoint as the Mac; outputs Vocal, Drum, Bass, Guitar, Other (other+piano).\n'
        'Windows uses 22050-frame hops and 66150-frame latency at 44100 Hz.\n'
        'OpenVINO 2025.4.0, Intel, Apache License 2.0; https://github.com/openvinotoolkit/openvino\n'
        'OpenVINO telemetry is opted out in the CatLive backend.\n'
        'PyTorch 2.2.2 CPU, BSD; https://github.com/pytorch/pytorch\n'
        'Python 3.11.12, PSF; additional Python distribution licenses remain under python/.\n'
        'All dependency versions are pinned in requirements.lock; redistribution notices are retained here and in python/Lib/site-packages.\n', encoding='utf-8')
    manifest = runtime_identity(lock)
    manifest['filesSHA256'] = {name: digest(target / name) for name in WORKERS + IR_FILES}
    (target / 'runtime.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    return verify_runtime(target, lock)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--verify', action='store_true')
    args = parser.parse_args()
    if platform.system() != 'Windows' or platform.machine().lower() not in ('amd64', 'x86_64'):
        raise RuntimeError('This runtime preparation requires Windows x64')
    target = args.output.resolve()
    root = Path(__file__).resolve().parents[2]
    lock = Path(__file__).with_name('requirements.lock')
    if target.exists():
        if args.verify:
            verify_runtime(target, lock)
        else:
            manifest = json.loads((target / 'runtime.json').read_text(encoding='utf-8'))
            if manifest.get('requirementsSHA256') != digest(lock) or manifest.get('modelSHA256') != MODEL_SHA:
                raise RuntimeError('The cached CatStem runtime uses different dependencies. Choose a new output directory.')
            refresh_runtime(target, root, lock)
        print('CatStem runtime verified:', target)
        return
    if args.verify:
        raise RuntimeError('CatStem runtime is missing.')
    target.parent.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(target.parent).free < 3 * 1024**3:
        raise RuntimeError('At least 3 GB of free build space is required')
    with tempfile.TemporaryDirectory(prefix='catstem-', dir=target.parent) as temporary:
        staging = Path(temporary)
        archive = staging / 'python.tar.gz'
        download(PYTHON_URL, archive, PYTHON_SHA)
        with tarfile.open(archive) as package:
            package.extractall(staging, filter='data')
        archive.unlink()
        python = staging / 'python/python.exe'
        subprocess.run([str(python), '-I', '-m', 'pip', 'install', '--no-cache-dir', '-r', str(lock)], check=True)
        download('https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/' + MODEL_NAME, staging / MODEL_NAME, MODEL_SHA)
        refresh_runtime(staging, root, lock)
        # Same filesystem: move the completed payload without duplicating 1.6 GiB.
        staging.replace(target)
    print('CatStem application runtime prepared:', target)


if __name__ == '__main__':
    main()
