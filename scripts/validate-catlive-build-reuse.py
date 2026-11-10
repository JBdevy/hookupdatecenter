#!/usr/bin/env python3
"""Validate immutable desktop packages against a corrected audio test run."""
import json
import os
import pathlib
import re
import subprocess
import time

WORKFLOW = '.github/workflows/catlive-macos-pkg.yml'
INTEL = 'audio-audit / offline-audio (macos-15-intel, x86_64)'
UI = 'audio-audit / ui-refresh'
BUILD_JOBS = {'windows', 'macos-pkg', 'macos-compatibility', 'compatibility',
              'integration / receiver (macos-26)', 'integration / receiver (windows-2022)', UI}
PUBLISH_ONLY = {WORKFLOW, 'scripts/validate-catlive-build-reuse.py',
                'scripts/test-catlive-build-reuse.py'}
TEST_ONLY = PUBLISH_ONLY | {'.github/workflows/catlive-audio-audit.yml',
                            'JarasLive/Tests/Apple/AudioRenderTests.swift',
                            'JarasLive/Tests/Apple/MobileAudioDriverTests.mm',
                            'JarasLive/Tests/Apple/VST3/GainFixture.cpp'}
TAIL_ONLY = PUBLISH_ONLY | {'JarasLive/Tests/Apple/VST3/GainFixture.cpp'}
TAIL_JOBS = {'validate-prior-audio', 'audio-tail'}
PRIOR_STEPS = {
    'Verify execution architecture',
    'Validate transport and realtime queues',
    'Validate prepared PCM, mobile clock and native output mapping',
    'Prepare generated native instrument fixture',
    'Validate audio continuity at 44.1 and 48 kHz',
    'Validate native effect DSP and instruments',
    'Validate failed media without stopping healthy stems',
}
TAIL_STEP = 'Validate VST3 state and metronome publication'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def is_tail_audit(jobs):
    return any(j['name'] == 'audio-tail' and j['conclusion'] != 'skipped' for j in jobs)


def validate_run(run, jobs, repository, audio=False):
    require(run['status'] == 'completed', 'Run must be complete')
    require(run['path'] == WORKFLOW, 'Unexpected workflow')
    require(run['head_repository']['full_name'] == repository, 'Unexpected source repository')
    require(run['event'] == 'workflow_dispatch', 'Expected a manually requested build')
    require(re.fullmatch('[0-9a-f]{40}', run['head_sha']), 'Invalid source SHA')
    require(len({j['name'] for j in jobs}) == len(jobs), 'Ambiguous job names')
    by_name = {j['name']: j for j in jobs}
    tail = audio and is_tail_audit(jobs)
    expected = TAIL_JOBS if tail else {INTEL, UI, 'audio-validation'} if audio else BUILD_JOBS
    for name in expected:
        require(name in by_name and by_name[name]['status'] == 'completed'
                and by_name[name]['conclusion'] == 'success', f'Required job did not pass: {name}')
    if audio:
        require(run['conclusion'] == 'success', 'Replacement audio run did not pass')
    else:
        require(run['conclusion'] in {'success', 'failure'}, 'Build was cancelled or timed out')
    for job in jobs:
        require(job['status'] == 'completed', 'Build still contains an active job')
        if job['conclusion'] not in {'success', 'skipped'}:
            require(not audio and job['name'] == INTEL and job['conclusion'] == 'failure',
                    f'Unreplaced job failure: {job["name"]}')


def validate_changes(build_to_audio, audio_to_publisher):
    require(set(build_to_audio) <= TEST_ONLY, 'Application/build code changed after packaging')
    require(set(audio_to_publisher) <= PUBLISH_ONLY, 'Untested changes after audio validation')


def validate_prior_audit(run, jobs, repository):
    """Reuse only the successful prefix of the actual Intel audit."""
    require(run['path'] == WORKFLOW and run['event'] == 'workflow_dispatch', 'Unexpected prior audit workflow')
    require(run['head_repository']['full_name'] == repository, 'Unexpected prior audit repository')
    require(re.fullmatch('[0-9a-f]{40}', run['head_sha']), 'Invalid prior audit source')
    matches = [j for j in jobs if j['name'] == INTEL]
    require(len(matches) == 1, 'Missing or ambiguous prior Intel audit')
    audit = matches[0]
    require(audit['status'] == 'completed' and audit['conclusion'] == 'failure', 'Prior Intel audit must have failed')
    steps = audit['steps']
    require(len({s['name'] for s in steps}) == len(steps), 'Ambiguous prior audit steps')
    by_name = {s['name']: s for s in steps}
    for name in PRIOR_STEPS:
        require(name in by_name and by_name[name]['status'] == 'completed'
                and by_name[name]['conclusion'] == 'success', f'Prior audio check did not pass: {name}')
    failed = [s['name'] for s in steps if s['conclusion'] not in {'success', 'skipped'}]
    require(failed == [TAIL_STEP] and by_name[TAIL_STEP]['conclusion'] == 'failure',
            'Only the final VST3/metronome/MIDI step may be replaced')
    return [{k: s[k] for k in ('name', 'status', 'conclusion')} for s in steps]


def api(path):
    path += ('&' if '?' in path else '?') + '_poll=' + str(time.time_ns())
    return json.loads(subprocess.check_output(['gh', 'api', path], text=True))


def read_run(repository, run_id):
    run = api(f'repos/{repository}/actions/runs/{run_id}')
    result = api(f'repos/{repository}/actions/runs/{run_id}/jobs?filter=latest&per_page=100')
    require(len(result['jobs']) == result['total_count'], 'Incomplete job evidence')
    return run, result['jobs']


def changed_files(start, end):
    subprocess.run(['git', 'fetch', '--no-tags', '--depth=1', 'origin', start, end], check=True)
    return subprocess.check_output(['git', 'diff', '--name-only', '--no-renames', start, end], text=True).splitlines()


def validate_tail_main():
    repository = os.environ['GITHUB_REPOSITORY']
    run_id = os.environ['CATLIVE_AUDIO_TAIL_FROM_RUN']
    require(run_id.isdigit(), 'Invalid prior run ID')
    run, jobs = read_run(repository, run_id)
    steps = validate_prior_audit(run, jobs, repository)
    changes = changed_files(run['head_sha'], os.environ['GITHUB_SHA'])
    require(set(changes) <= TAIL_ONLY, 'Code outside the VST3 fixture/publication automation changed')
    evidence = {'prior_run': run_id, 'prior_sha': run['head_sha'], 'current_sha': os.environ['GITHUB_SHA'],
                'prior_steps': steps, 'test_only_changes': changes}
    pathlib.Path('catlive-audio-tail-evidence.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print('All earlier Intel audio checks passed; application and test drivers are unchanged. Repeating the complete final step.')


def main():
    repository = os.environ['GITHUB_REPOSITORY']
    build_id, audio_id = os.environ['REUSE_BUILD_RUN'], os.environ['REUSE_AUDIO_RUN']
    version = os.environ['VERSION']
    require(build_id.isdigit() and audio_id.isdigit() and build_id != audio_id, 'Invalid run IDs')
    require(re.fullmatch(r'[0-9]+\.[0-9]{2}', version), 'Invalid public version')
    records, raw = [], []
    for run_id, is_audio in ((build_id, False), (audio_id, True)):
        run, jobs = read_run(repository, run_id)
        validate_run(run, jobs, repository, audio=is_audio)
        raw.append((run, jobs))
        records.append({'id': run_id, 'sha': run['head_sha'], 'url': run['html_url'],
                        'jobs': [{k: j[k] for k in ('name', 'status', 'conclusion')} for j in jobs]})
    build_sha, audio_sha = (r['sha'] for r in records)
    subprocess.run(['git', 'fetch', '--no-tags', '--depth=1', 'origin', build_sha, audio_sha], check=True)
    def changed(start, end):
        return subprocess.check_output(['git', 'diff', '--name-only', '--no-renames', start, end], text=True).splitlines()
    test_changes = changed(build_sha, audio_sha)
    publisher_changes = changed(audio_sha, os.environ['GITHUB_SHA'])
    validate_changes(test_changes, publisher_changes)
    prior_steps = None
    if is_tail_audit(raw[1][1]):
        require(set(test_changes) <= TAIL_ONLY, 'Tail validation cannot replace other audio changes')
        prior_steps = validate_prior_audit(*raw[0], repository)
    evidence = {'version': version, 'build': records[0], 'audio': records[1],
                'test_only_changes': test_changes, 'publisher_only_changes': publisher_changes,
                'prior_audio_steps': prior_steps}
    pathlib.Path('catlive-build-reuse-validation.json').write_text(json.dumps(evidence, indent=2) + '\n')
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write(f'source_sha={audio_sha}\n')
    print(f'Application sources are identical. Packages: {build_sha}; passing audio audit: {audio_sha}')


if __name__ == '__main__':
    if os.environ.get('CATLIVE_AUDIO_TAIL_FROM_RUN'):
        validate_tail_main()
    else:
        main()
