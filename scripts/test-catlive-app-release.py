#!/usr/bin/env python3
"""Exercise app-repository publishing against disposable local Git repositories."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap

ROOT = Path(__file__).resolve().parents[1]
ORIGIN = 'https://github.com/JBdevy/vshookapploja.git'

def run(*args, cwd=None, env=None, check=True):
    return subprocess.run(args, cwd=cwd, env=env, check=check, text=True, capture_output=True)

with tempfile.TemporaryDirectory(prefix='catlive-app-repo-test-') as temporary:
    base = Path(temporary)
    app, bare = base/'app', base/'app.git'
    run('git', 'init', '--bare', str(bare))
    run('git', 'init', '-b', 'main', str(app))
    run('git', 'config', 'user.name', 'Release Test', cwd=app)
    run('git', 'config', 'user.email', 'test@example.invalid', cwd=app)
    run('git', 'remote', 'add', 'origin', ORIGIN, cwd=app)
    run('git', 'config', f'url.{bare}.insteadOf', ORIGIN, cwd=app)
    (app/'README').write_text('original\n')
    run('git', 'add', '.', cwd=app)
    run('git', 'commit', '-m', 'Initial', cwd=app)
    run('git', 'push', '-u', 'origin', 'main', cwd=app)
    run('git', 'symbolic-ref', 'HEAD', 'refs/heads/main', cwd=bare)
    release_template = ROOT/'.github/workflows/catlive-app-release.yml'
    if not release_template.exists(): release_template = ROOT/'scripts/catlive-app-release.yml'
    for src, dst in [(ROOT/'build catlive app.command', 'build catlive app.command'),
                     (ROOT/'build catlive ios.command', 'build catlive ios.command'),
                     (ROOT/'scripts/publish-catlive-app.sh', 'scripts/publish-catlive-app.sh'),
                     (ROOT/'scripts/test-catlive-app-release.py', 'scripts/test-catlive-app-release.py'),
                     (ROOT/'.github/workflows/catlive-ios-appstore.yml', '.github/workflows/catlive-ios-appstore.yml'),
                     (release_template, '.github/workflows/catlive-app-release.yml')]:
        target=app/dst; target.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(src,target)
    (app/'JarasLive').mkdir()
    (app/'JarasLive/test.swift').write_text('// source lives in the app repo\n')
    (app/'README').write_text('unrelated staged change\n')
    run('git', 'add', 'README', cwd=app)
    fake=base/'bin'; fake.mkdir()
    gh=fake/'gh'
    gh.write_text("""#!/usr/bin/env python3
import sys
args=sys.argv[1:]
if args[:2] == ['auth', 'status']: sys.exit(0)
if args[:2] == ['secret', 'list']:
    print('\\n'.join('IOS_TEAM_ID IOS_CERT_P12_BASE64 IOS_CERT_PASSWORD CATLIVE_IOS_PROVISION_PROFILE_BASE64 CATLIVE_APP_STORE_CONNECT_KEY_ID CATLIVE_APP_STORE_CONNECT_ISSUER_ID CATLIVE_APP_STORE_CONNECT_API_KEY_P8_BASE64'.split())); sys.exit(0)
raise SystemExit('Unexpected gh command: '+repr(args))
""")
    gh.chmod(0o755)
    env=dict(os.environ, PATH=str(fake)+':'+os.environ['PATH'], CATLIVE_BUILD_NO_PAUSE='1')
    env.pop('CATLIVE_MIN_BUILD_NUMBER',None); env.pop('CATLIVE_APP_REPO_DIR',None)
    for build,minimum in [(1001,None),(1002,None),(1020,'1020'),(1021,'1019')]:
        if minimum is not None: env['CATLIVE_MIN_BUILD_NUMBER']=minimum
        result=run('bash',str(app/'build catlive app.command'),'1.01','Publish local app source',cwd=app,env=env,check=False)
        assert result.returncode == 0, result.stdout+result.stderr
        tag=f'catlive-app-v1.01-build{build}'
        manifest=json.loads(run('git','show',f'{tag}:.github/catlive-app-release.json',cwd=bare).stdout)
        source=run('git','rev-parse',f'{tag}^',cwd=bare).stdout.strip()
        assert manifest == dict(version='1.01',build_number=str(build),source_ref=source)
        assert run('git','show',f'{source}:JarasLive/test.swift',cwd=bare).stdout == '// source lives in the app repo\n'
        workflow=run('git','show',f'{tag}:.github/workflows/catlive-app-release.yml',cwd=bare).stdout
        reusable=run('git','show',f'{tag}:.github/workflows/catlive-ios-appstore.yml',cwd=bare).stdout
        assert 'uses: ./.github/workflows/catlive-ios-appstore.yml' in workflow
        assert 'hookupdatecenter' not in workflow+reusable
        assert 'files: release/CatLive.ipa' in workflow
        assert 'fetch-depth: 2' in workflow
        code=textwrap.dedent('          import json, os, re, subprocess'+workflow.split('          import json, os, re, subprocess',1)[1].split('\n          PY',1)[0])
        prepare=run('python3','-c',code,cwd=app,env=dict(env,RELEASE_TAG=tag,GITHUB_OUTPUT=str(base/'outputs')),check=False)
        assert prepare.returncode == 0,prepare.stderr
        assert run('git','diff','--cached','--name-only',cwd=app).stdout.strip() == 'README'
        assert run('git','show','HEAD:README',cwd=app).stdout == 'original\n'
    before=run('git','show-ref',cwd=bare).stdout
    invalid=run('bash',str(app/'build catlive app.command'),'1.0.1','Bad version',cwd=app,env=env,check=False)
    assert invalid.returncode != 0
    assert run('git','show-ref',cwd=bare).stdout == before
print('CATLIVE_APP_OWN_REPOSITORY_RELEASE_OK: local source, local workflow, parent SHA, sequential builds, atomic tag push, unrelated changes preserved')
