#!/usr/bin/env python3
"""Notarize without a long-lived notarytool --wait process; resume known submissions."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import uuid


class NotaryFailure(RuntimeError):
    pass


def package_digest(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(4 * 1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def valid_id(value):
    try:
        return str(uuid.UUID(str(value)))
    except (ValueError, TypeError, AttributeError):
        return None


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def notarize(package, result, timeout=5400, poll=20, *, runner=subprocess.run,
             sleep=time.sleep, clock=time.monotonic, environment=None):
    env = os.environ if environment is None else environment
    keys = ['APPLE_ID', 'APPLE_APP_SPECIFIC_PASSWORD', 'APPLE_TEAM_ID']
    credentials = [env.get(key, '') for key in keys]
    if not all(credentials):
        raise NotaryFailure('Missing Apple notarization credentials.')
    auth = ['--apple-id', credentials[0], '--password', credentials[1], '--team-id', credentials[2]]
    digest = package_digest(package)
    state_path = result.with_suffix('.submission.json')
    deadline = clock() + timeout

    def safe(text):
        for secret in credentials:
            text = text.replace(secret, '***')
        return text

    def invoke(action, arguments, attempts=3):
        for attempt in range(attempts):
            remaining = deadline - clock()
            if remaining <= 0:
                raise NotaryFailure('Notarization timed out; the recorded submission can be resumed.')
            command = ['xcrun', 'notarytool', action, *arguments, *auth, '--output-format', 'json']
            try:
                response = runner(command, capture_output=True, text=True, timeout=min(300, remaining))
                output = response.stdout or ''
                error = response.stderr or ''
                code = response.returncode
            except subprocess.TimeoutExpired:
                output, error, code = '', 'notarytool timed out', -1
            try:
                value = json.loads(output)
            except (ValueError, TypeError):
                value = None
            # Retain the accepted submission identity even if the process crashes afterwards.
            if action == 'submit' and isinstance(value, dict) and valid_id(value.get('id')):
                return value
            if code == 0 and isinstance(value, dict):
                return value
            diagnostic = safe((error or output or 'No response from notarytool').strip())
            result.parent.mkdir(parents=True, exist_ok=True)
            with result.with_suffix('.stderr.log').open('a') as log:
                log.write(f'{action} attempt {attempt + 1}, exit {code}: {diagnostic}\n')
            transient = code < 0 or code in (134, 138, 139) or any(token in diagnostic.lower() for token in (
                'timed out', 'timeout', 'network', 'connection', 'temporarily', 'http 500', 'http 502', 'http 503', 'http 504'))
            if not transient or attempt == attempts - 1:
                raise NotaryFailure(f'notarytool {action} failed (exit {code}): {diagnostic}')
            print(f'notarytool {action}: transient failure; retry {attempt + 2}/{attempts}.', flush=True)
            sleep(min(5 * (attempt + 1), max(0, deadline - clock())))
        raise NotaryFailure('No notarization response.')

    submission = None
    if state_path.exists():
        try:
            state = json.loads(state_path.read_text())
            if state.get('sha256') == digest:
                submission = valid_id(state.get('id'))
        except (ValueError, OSError):
            pass
    if submission is None:
        # The previous CI crash occurred in accelerated submission. Use the standard
        # upload path and poll with short, separate notarytool processes afterwards.
        submitted = invoke('submit', [str(package), '--no-wait', '--no-s3-acceleration'])
        submission = valid_id(submitted.get('id'))
        if submission is None:
            raise NotaryFailure('Apple did not return a valid submission ID.')
        write_json(state_path, {'id': submission, 'sha256': digest})
    print(f'Apple notarization submission: {submission}', flush=True)
    last_status = None
    while clock() < deadline:
        value = invoke('info', [submission])
        if valid_id(value.get('id')) != submission:
            raise NotaryFailure('Apple returned an unexpected submission ID.')
        write_json(result, value)
        status = value.get('status', '')
        if status != last_status:
            print(f'Apple notarization: {status}', flush=True)
            last_status = status
        if status == 'Accepted':
            return value
        if status in ('Invalid', 'Rejected'):
            try:
                write_json(result.with_suffix('.issues.json'), invoke('log', [submission], attempts=1))
            except NotaryFailure as error:
                print(str(error), flush=True)
            raise NotaryFailure(f'Apple rejected submission {submission}: {status}. See the notarization artifacts.')
        if status != 'In Progress':
            raise NotaryFailure(f'Unexpected notarization status: {status!r}.')
        sleep(min(poll, max(0, deadline - clock())))
    raise NotaryFailure(f'Notarization timed out. Submission {submission} is saved for resuming.')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('package', type=Path)
    parser.add_argument('--result', type=Path, required=True)
    args = parser.parse_args()
    try:
        notarize(args.package.resolve(strict=True), args.result)
    except (NotaryFailure, OSError) as error:
        raise SystemExit(str(error)) from None


if __name__ == '__main__':
    main()
