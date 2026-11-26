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
        jobs.append({'name': 'audio-tail', 'status': 'completed', 'conclusion': 'skipped'})
        run = {**self.run, 'conclusion': 'success'}
        reuse.validate_run(run, jobs, 'owner/repo', audio=True)
        for index in range(len(jobs) - 1):
            invalid = copy.deepcopy(jobs)
            invalid[index]['conclusion'] = 'skipped'
            with self.assertRaises(ValueError):
                reuse.validate_run(run, invalid, 'owner/repo', audio=True)

    def test_tail_requires_prior_validation_and_actual_intel_tail_success(self):
        jobs = [{'name': n, 'status': 'completed', 'conclusion': 'success'} for n in reuse.TAIL_JOBS]
        reuse.validate_run({**self.run, 'conclusion': 'success'}, jobs, 'owner/repo', audio=True)
        for name in reuse.TAIL_JOBS:
            for conclusion in ['skipped', 'failure', 'cancelled']:
                invalid = copy.deepcopy(jobs)
                next(j for j in invalid if j['name'] == name)['conclusion'] = conclusion
                with self.assertRaises(ValueError):
                    reuse.validate_run({**self.run, 'conclusion': 'success'}, invalid, 'owner/repo', audio=True)

    def test_tail_rejects_any_missing_or_unpassed_prior_audio_check(self):
        steps = [{'name': n, 'status': 'completed', 'conclusion': 'success'} for n in sorted(reuse.PRIOR_STEPS)]
        steps.append({'name': reuse.TAIL_STEP, 'status': 'completed', 'conclusion': 'failure'})
        jobs = [{'name': reuse.INTEL, 'status': 'completed', 'conclusion': 'failure', 'steps': steps}]
        reuse.validate_prior_audit(self.run, jobs, 'owner/repo')
        for index in range(len(steps) - 1):
            for conclusion in ['failure', 'skipped', None]:
                invalid = copy.deepcopy(jobs)
                invalid[0]['steps'][index]['conclusion'] = conclusion
                with self.assertRaises(ValueError):
                    reuse.validate_prior_audit(self.run, invalid, 'owner/repo')
            invalid = copy.deepcopy(jobs)
            del invalid[0]['steps'][index]
            with self.assertRaises(ValueError):
                reuse.validate_prior_audit(self.run, invalid, 'owner/repo')
        with self.assertRaises(ValueError):
            reuse.validate_prior_audit(self.run, jobs + jobs, 'owner/repo')
        with self.assertRaises(ValueError):
            reuse.validate_prior_audit(self.run, jobs, 'untrusted/repo')

    def test_tail_scope_excludes_product_other_fixtures_and_test_drivers(self):
        self.assertIn('JarasLive/Tests/Apple/VST3/GainFixture.cpp', reuse.TAIL_ONLY)
        for path in ['JarasLive/Apple/Bridge/JarasVST3.mm', 'JarasLive/Tests/Apple/AudioRenderTests.swift',
                     'JarasLive/scripts/test-vst3-state-stream.sh', '.github/workflows/catlive-audio-audit.yml']:
            self.assertNotIn(path, reuse.TAIL_ONLY)

    def test_only_portable_fixture_and_publisher_changes_are_allowed(self):
        reuse.validate_changes(list(reuse.TEST_ONLY), list(reuse.PUBLISH_ONLY))
        for path in ['JarasLive/Apple/Shared/StemAudioPlayback.swift', 'JarasLive/Windows/Source/Tests.cpp',
                     'JarasLive/scripts/test-audio.sh', 'JarasLive/Windows/build.ps1', 'package.json']:
            with self.assertRaises(ValueError):
                reuse.validate_changes([path], [])
            with self.assertRaises(ValueError):
                reuse.validate_changes([], [path])

    def test_mobile_pcm_fixture_does_not_allow_output_driver_changes(self):
        fixture = 'JarasLive/Tests/Apple/MobileAudioDriverTests.mm'
        reuse.validate_changes([fixture], [])
        with self.assertRaises(ValueError):
            reuse.validate_changes([], [fixture])
        for path in ['JarasLive/Apple/Bridge/JarasMobileAudioIO.inc',
                     'JarasLive/Apple/Bridge/JarasEffects.mm',
                     'JarasLive/scripts/test-mobile-audio-driver.sh']:
            with self.assertRaises(ValueError):
                reuse.validate_changes([fixture, path], [])


if __name__ == '__main__':
    unittest.main()
