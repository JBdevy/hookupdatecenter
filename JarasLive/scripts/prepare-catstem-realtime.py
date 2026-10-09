#!/usr/bin/env python3
"""Package an isolated, optional macOS 14 / Apple Silicon CatStem helper.

The application and existing Intel/macOS 12 helper keep their deployment target.
No model conversion/inference occurs at build time. Every wheel and model asset
is hash pinned; no weights, Python packages or tools are downloaded at runtime.
"""
import hashlib
import importlib.util
import json
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
RUNTIME = ROOT / 'build/StemSeparationRuntime'
TARGET = RUNTIME / 'realtime-arm64'
LOCK = ROOT / 'scripts/catstem-realtime-requirements.lock'
MODELS = {
    'htdemucs_6s.safetensors': 'd298f7f746bf53c21baad44fb08e88807ef47feb551dd22f1601a546c85b8e02',
    'htdemucs_6s_config.json': 'd5e18c0209be583027d6eb5ec3013a02cd7ef55bc3096e644d8d3577d92e9bd0',
}


def download_model(name, path):
    subprocess.run(['/usr/bin/curl', '-fL', '--retry', '3', '--connect-timeout', '30',
                    '-o', str(path), 'https://huggingface.co/ssmall256/demucs-mlx/resolve/main/' + name], check=True)
    if hashlib.sha256(path.read_bytes()).hexdigest() != MODELS[name]:
        raise RuntimeError('Model checksum mismatch: ' + name)


def audit_binaries(folder):
    spec = importlib.util.spec_from_file_location('catstem_deployment', ROOT / 'scripts/test-macos-deployment.py')
    module = importlib.util.module_from_spec(spec)
    # dataclass resolves its defining module during import.
    import sys
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    count = 0
    for path in folder.rglob('*'):
        if path.is_symlink() or not path.is_file():
            continue
        slices = module.read_macho(path)
        if slices is None:
            continue
        count += 1
        if any(item.minimum > (14, 0, 0) for item in slices) or not any(item.arch == 'arm64' for item in slices):
            raise RuntimeError('Helper must support macOS 14 on Apple Silicon: ' + str(path))
    if count < 3:
        raise RuntimeError('Missing native helper libraries')


def main():
    if platform.system() != 'Darwin':
        raise RuntimeError('Prepare this runtime on macOS.')
    native_arch = platform.machine()
    source_python = RUNTIME / 'arm64/python'
    build_python = RUNTIME / native_arch / 'python/bin/python3.11'
    if not source_python.is_dir() or not build_python.is_file():
        raise RuntimeError('Run prepare-catstem.py first.')
    manifest = {'version': 1, 'architecture': 'arm64', 'minimumMacOS': '14.0',
                'requirements': hashlib.sha256(LOCK.read_bytes()).hexdigest(), 'models': MODELS}
    marker = TARGET / 'runtime.json'
    if marker.exists() and json.loads(marker.read_text()) == manifest:
        audit_binaries(TARGET)
        print('CatStem realtime helper already prepared:', TARGET)
        return
    with tempfile.TemporaryDirectory(prefix='catstem-realtime-', dir=RUNTIME.parent) as temp:
        staging = Path(temp)
        python_dir = staging / 'python'
        shutil.copytree(source_python, python_dir, symlinks=True,
                        ignore=shutil.ignore_patterns('site-packages', '__pycache__', '*.pyc'))
        site = python_dir / 'lib/python3.11/site-packages'
        site.mkdir(parents=True, exist_ok=True)
        subprocess.run([str(build_python), '-I', '-m', 'pip', 'install', '--no-cache-dir', '--no-compile',
                        '--no-deps', '--require-hashes', '--only-binary=:all:', '--platform', 'macosx_14_0_arm64',
                        '--platform', 'macosx_11_0_arm64', '--implementation', 'cp', '--python-version', '3.11',
                        '--abi', 'cp311', '--target', str(site), '-r', str(LOCK)], check=True)
        models = staging / 'models'
        models.mkdir()
        for name in MODELS:
            download_model(name, models / name)
        audit_binaries(staging)
        (staging / 'runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')
        # Preserve the previous helper until the complete replacement has passed
        # its hash and deployment audits; this is a build-only directory.
        previous = RUNTIME / 'realtime-arm64.previous'
        if previous.exists():
            shutil.rmtree(previous)
        if TARGET.exists():
            TARGET.rename(previous)
        try:
            shutil.copytree(staging, TARGET, symlinks=True)
        except Exception:
            if TARGET.exists():
                shutil.rmtree(TARGET)
            if previous.exists():
                previous.rename(TARGET)
            raise
        if previous.exists():
            shutil.rmtree(previous)
    print('CatStem realtime helper ready:', TARGET)


if __name__ == '__main__':
    main()
