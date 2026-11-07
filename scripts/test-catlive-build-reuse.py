import copy
import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location('reuse', pathlib.Path(__file__).with_name('validate-catlive-build-reuse.py'))
reuse = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reuse)


class ReuseValidationTests(unittest.TestCase):
    def setUp(self):
        self.run = {'status': 'completed', 'conclusion': 'failure', 'path': reuse.WORKFLOW,
                    'head_repository': {'full_name': 'owner/repo'}, 'event': 'workflow_dispatch',
                    'head_sha': 'a' * 40}
        self.jobs = [{'name': n, 'status': 'completed', 'conclusion': 'success'} for n in reuse.BUILD_JOBS]
        self.jobs.append({'name': reuse.INTEL, 'status': 'completed', 'conclusion': 'failure'})

    def test_requires_all_packaging_and_exchange_checks(self):
        reuse.validate_run(self.run, self.jobs, 'owner/repo')
        for index in range(len(self.jobs) - 1):
            jobs = copy.deepcopy(self.jobs)
            jobs[index]['conclusion'] = 'failure'
            with self.assertRaises(ValueError):
                reuse.validate_run(self.run, jobs, 'owner/repo')
            with self.assertRaises(ValueError):
                reuse.validate_run(self.run, self.jobs[:index] + self.jobs[index + 1:], 'owner/repo')

    def test_requires_completed_trusted_workflow(self):
        for key, value in [('status', 'in_progress'), ('conclusion', 'cancelled'),
                           ('path', 'other.yml'), ('event', 'pull_request'), ('head_sha', 'bad')]:
            with self.assertRaises(ValueError):
                reuse.validate_run({**self.run, key: value}, self.jobs, 'owner/repo')
        with self.assertRaises(ValueError):
            reuse.validate_run(self.run, self.jobs, 'other/repo')

    def test_no_unrelated_failure_is_replaced(self):
        jobs = self.jobs + [{'name': 'new check', 'status': 'completed', 'conclusion': 'failure'}]
        with self.assertRaises(ValueError):
            reuse.validate_run(self.run, jobs, 'owner/repo')

    def test_replacement_requires_both_audio_architectures_and_visual_refresh(self):
        jobs = [{'name': n, 'status': 'completed', 'conclusion': 'success'} for n in (reuse.INTEL, reuse.UI, 'audio-validation')]
        run = {**self.run, 'conclusion': 'success'}
        reuse.validate_run(run, jobs, 'owner/repo', audio=True)
        for index in range(len(jobs)):
            invalid = copy.deepcopy(jobs)
            invalid[index]['conclusion'] = 'skipped'
            with self.assertRaises(ValueError):
                reuse.validate_run(run, invalid, 'owner/repo', audio=True)

    def test_only_portable_fixture_and_publisher_changes_are_allowed(self):
        reuse.validate_changes(list(reuse.TEST_ONLY), list(reuse.PUBLISH_ONLY))
        for path in ['JarasLive/Apple/Shared/StemAudioPlayback.swift', 'JarasLive/Windows/Source/Tests.cpp',
                     'JarasLive/scripts/test-audio.sh', 'JarasLive/Windows/build.ps1', 'package.json']:
            with self.assertRaises(ValueError):
                reuse.validate_changes([path], [])
            with self.assertRaises(ValueError):
                reuse.validate_changes([], [path])


if __name__ == '__main__':
    unittest.main()
