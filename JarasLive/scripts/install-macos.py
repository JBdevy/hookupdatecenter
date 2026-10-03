#!/usr/bin/env python3
"""Install the signed CatLive build after the current app has been closed."""
from pathlib import Path
import datetime
import plistlib
import shutil
import subprocess
import sys
import tempfile


def install(source: Path) -> None:
    source = source.resolve(strict=True)
    with (source / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info.get('CFBundleIdentifier') != 'com.hookdeveloper.jaraslive.mac' or info.get('CFBundleName') != 'CatLive':
        raise SystemExit('O arquivo não é um build do CatLive para macOS.')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(source)], check=True)
    processes = subprocess.check_output(['ps', '-axo', 'command='], text=True)
    executables = ['/CatLive.app/Contents/MacOS/CatLive', '/Jaras Live.app/Contents/MacOS/Jaras Live']
    if any(executable in command for command in processes.splitlines() for executable in executables):
        raise SystemExit('Salve e feche o aplicativo antes de instalar o CatLive.')
    applications = Path.home() / 'Applications'
    applications.mkdir(exist_ok=True)
    target = applications / 'CatLive.app'
    legacy = applications / 'Jaras Live.app'
    if source in (target, legacy):
        raise SystemExit('Escolha o build, não o aplicativo já instalado.')
    # Stage and validate before touching either installed bundle. Keep both
    # backups for rollback; the old product must not remain as a second app.
    with tempfile.TemporaryDirectory(prefix='.catlive-install-', dir=applications) as staging:
        staged = Path(staging) / 'CatLive.app'
        subprocess.run(['ditto', str(source), str(staged)], check=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(staged)], check=True)
        backup = Path(tempfile.mkdtemp(prefix='CatLive-before-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S') + '-'))
        moved = []
        try:
            for current in (target, legacy):
                if current.exists():
                    saved = backup / current.name
                    shutil.move(str(current), str(saved))
                    moved.append((saved, current))
            staged.rename(target)
        except Exception:
            for saved, current in reversed(moved):
                shutil.move(str(saved), str(current))
            raise
    print('Installed:', target, flush=True)
    print('Backup:', backup, flush=True)
    subprocess.run(['open', '-a', str(target)], check=True)


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Uso: install-macos.py /caminho/do/build/CatLive.app')
    install(Path(sys.argv[1]))
