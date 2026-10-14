#!/usr/bin/env python3
"""Exercise the release command against disposable local repositories, never GitHub."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FILES = ['build catlive app.command', 'build catlive ios.command', 'scripts/catlive-app-release.yml', 'scripts/test-catlive-app-release.py']


def run(*args, cwd=None, env=None, check=True):
    return subprocess.run(args, cwd=cwd, env=env, check=check, text=True, capture_output=True)


def repo(folder, bare):
    run('git', 'init', '--bare', str(bare))
    run('git', 'init', '-b', 'main', str(folder))
    run('git', 'config', 'user.name', 'Release Test', cwd=folder)
    run('git', 'config', 'user.email', 'test@example.invalid', cwd=folder)
    run('git', 'remote', 'add', 'origin', str(bare), cwd=folder)
    (folder / 'README').write_text('original\n')
    run('git', 'add', '.', cwd=folder)
    run('git', 'commit', '-m', 'Initial', cwd=folder)
    run('git', 'push', '-u', 'origin', 'main', cwd=folder)
    run('git', 'symbolic-ref', 'HEAD', 'refs/heads/main', cwd=bare)


with tempfile.TemporaryDirectory(prefix='catlive-release-test-') as temporary:
    base = Path(temporary)
    source, release = base / 'source', base / 'release'
    source_bare, release_bare = base / 'source.git', base / 'release.git'
    repo(source, source_bare)
    repo(release, release_bare)
    for name in FILES:
        target = source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / name, target)
    (source / 'JarasLive').mkdir()
    (source / 'JarasLive/test.swift').write_text('// change to publish\n')
    (source / '.github/workflows').mkdir(parents=True)
    (source / '.github/workflows/catlive-ios-appstore.yml').write_text('name: Test\n')
    (source / 'README').write_text('unrelated staged change\n')
    run('git', 'add', 'README', cwd=source)
    fake = base / 'bin'
    fake.mkdir()
    gh = fake / 'gh'
    gh.write_text('''#!/usr/bin/env python3
import os, subprocess, sys
args = sys.argv[1:]
if args[:2] == ['auth', 'status']: sys.exit(0)
if args[:2] == ['secret', 'list']:
    print('\\n'.join('IOS_TEAM_ID IOS_CERT_P12_BASE64 IOS_CERT_PASSWORD CATLIVE_IOS_PROVISION_PROFILE_BASE64 CATLIVE_APP_STORE_CONNECT_KEY_ID CATLIVE_APP_STORE_CONNECT_ISSUER_ID CATLIVE_APP_STORE_CONNECT_API_KEY_P8_BASE64'.split())); sys.exit(0)
if args[:2] == ['repo', 'clone']:
    sys.exit(subprocess.call(['git', 'clone', '--depth', '1', '--no-tags', os.environ['CATLIVE_TEST_RELEASE_ORIGIN'], args[3]]))
raise SystemExit('Unexpected gh command: ' + repr(args))
''')
    gh.chmod(0o755)
    env = dict(os.environ, PATH=str(fake) + ':' + os.environ['PATH'], CATLIVE_BUILD_NO_PAUSE='1', CATLIVE_TEST_RELEASE_ORIGIN=str(release_bare))
    for build in [1001, 1002]:
        result = run('bash', str(source / FILES[0]), '1.01', 'Test release', cwd=source, env=env, check=False)
        assert result.returncode == 0, result.stdout + result.stderr
        tag = f'catlive-app-v1.01-build{build}'
        manifest = json.loads(run('git', 'show', f'{tag}:.github/catlive-app-release.json', cwd=release_bare).stdout)
        head = run('git', 'rev-parse', 'HEAD', cwd=source).stdout.strip()
        assert manifest == dict(version='1.01', build_number=str(build), source_ref=head)
        workflow = run('git', 'show', f'{tag}:.github/workflows/catlive-app-release.yml', cwd=release_bare).stdout
        assert f'catlive-ios-appstore.yml@{head}' in workflow
        assert '__CATLIVE_SOURCE_SHA__' not in workflow
        assert 'files: release/CatLive.ipa' in workflow
        assert run('git', 'show', f'{tag}:README', cwd=release_bare).stdout == 'original\n'
        assert run('git', 'diff', '--cached', '--name-only', cwd=source).stdout.strip() == 'README'
        assert run('git', 'show', 'HEAD:README', cwd=source).stdout == 'original\n'
    before = run('git', 'show-ref', cwd=release_bare).stdout
    invalid = run('bash', str(source / FILES[0]), '1.0.1', 'Bad version', cwd=source, env=env, check=False)
    assert invalid.returncode != 0
    assert run('git', 'show-ref', cwd=release_bare).stdout == before
print('CATLIVE_APP_RELEASE_COMMAND_OK: tag trigger, pinned SHA, sequential builds, IPA only, isolated commits, invalid version rejected')
