#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('notarize', Path(__file__).with_name('notarize-catlive-pkg.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
ID = '390b913d-b2a4-47ee-893d-0d722468b938'
ENV = {'APPLE_ID': 'review@example.test', 'APPLE_APP_SPECIFIC_PASSWORD': 'test-secret', 'APPLE_TEAM_ID': 'TESTTEAM'}


class NotaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.package = root / 'Catlive.pkg'
        self.package.write_bytes(b'signed test package')
        self.result = root / 'notary.json'
        self.commands = []
        self.elapsed = 0

    def run_notary(self, responses, timeout=90):
        def run(command, **kwargs):
            self.commands.append(command)
            action, code, value = responses.pop(0)
            self.assertEqual(command[2], action)
            return subprocess.CompletedProcess(command, code, json.dumps(value) if isinstance(value, dict) else value, '')
        def sleep(seconds):
            self.elapsed += seconds
        return module.notarize(self.package, self.result, timeout=timeout, poll=1,
            runner=run, sleep=sleep, clock=lambda: self.elapsed, environment=ENV)

    def test_bus_error_retries_submission_without_acceleration_then_polls(self):
        value = self.run_notary([('submit', -10, ''), ('submit', 0, {'id': ID}),
            ('info', -10, ''), ('info', 0, {'id': ID, 'status': 'In Progress'}),
            ('info', 0, {'id': ID, 'status': 'Accepted'})])
        self.assertEqual(value['status'], 'Accepted')
        for command in self.commands[:2]:
            self.assertIn('--no-s3-acceleration', command)
            self.assertIn('--no-wait', command)
            self.assertNotIn('--wait', command)
        self.assertEqual(json.loads(self.result.with_suffix('.submission.json').read_text())['id'], ID)

    def test_recorded_id_after_crash_does_not_resubmit(self):
        self.run_notary([('submit', -10, {'id': ID}), ('info', 0, {'id': ID, 'status': 'Accepted'})])
        self.assertEqual([command[2] for command in self.commands], ['submit', 'info'])
        self.commands = []
        self.run_notary([('info', 0, {'id': ID, 'status': 'Accepted'})])
        self.assertEqual(len(self.commands), 1)
        self.package.write_bytes(b'different signed package')
        self.run_notary([('submit', 0, {'id': ID}), ('info', 0, {'id': ID, 'status': 'Accepted'})])
        self.assertEqual(self.commands[1][2], 'submit')

    def test_rejection_is_terminal_and_preserves_apple_log(self):
        with self.assertRaisesRegex(module.NotaryFailure, 'rejected'):
            self.run_notary([('submit', 0, {'id': ID}), ('info', 0, {'id': ID, 'status': 'Invalid'}),
                             ('log', 0, {'issues': ['invalid signature']})])
        self.assertTrue(self.result.with_suffix('.issues.json').exists())
        self.assertEqual(sum(command[2] == 'submit' for command in self.commands), 1)

    def test_credentials_error_is_not_retried_or_exposed(self):
        with self.assertRaises(module.NotaryFailure) as error:
            self.run_notary([('submit', 1, 'Invalid credentials: test-secret review@example.test')])
        self.assertNotIn('test-secret', str(error.exception))
        self.assertNotIn('review@example.test', self.result.with_suffix('.stderr.log').read_text())
        self.assertEqual(len(self.commands), 1)

    def test_timeout_does_not_accept_pending_submission(self):
        with self.assertRaisesRegex(module.NotaryFailure, 'timed out'):
            self.run_notary([('submit', 0, {'id': ID}), ('info', 0, {'id': ID, 'status': 'In Progress'})], timeout=1)
        self.assertEqual(json.loads(self.result.read_text())['status'], 'In Progress')

    def test_wrong_submission_identity_fails(self):
        with self.assertRaisesRegex(module.NotaryFailure, 'unexpected submission'):
            self.run_notary([('submit', 0, {'id': ID}), ('info', 0, {'id': '00000000-0000-4000-8000-000000000001', 'status': 'Accepted'})])


if __name__ == '__main__':
    unittest.main()
