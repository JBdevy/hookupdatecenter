"""Exercise signing failures without certificates or Apple's timestamp service."""

import contextlib
import importlib.util
import io
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("codesign_retry", Path(__file__).with_name("codesign-with-retry.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SigningTests(unittest.TestCase):
    arguments = ["--force", "--sign", "Fixture Identity", "--options", "runtime", "--timestamp", "Fixture App.app"]

    def invoke(self, outcomes):
        with patch.object(module.subprocess, "run", side_effect=outcomes) as runner, \
             patch.object(module.time, "sleep") as sleeper, \
             contextlib.redirect_stdout(io.StringIO()):
            module.sign(self.arguments)
            return runner, sleeper

    def test_apple_timestamp_outage_recovers_without_dropping_timestamp(self):
        failure = subprocess.CompletedProcess([], 1, "library.so: The timestamp service is not available.\n")
        runner, sleeper = self.invoke([failure, failure, subprocess.CompletedProcess([], 0, "signed\n")])
        self.assertEqual(runner.call_count, 3)
        for call in runner.call_args_list:
            self.assertEqual(call.args[0], ["/usr/bin/codesign", *self.arguments])
            self.assertEqual(call.kwargs["stdin"], subprocess.DEVNULL)
        self.assertEqual([call.args[0] for call in sleeper.call_args_list], [10, 20])

    def test_certificate_error_is_not_retried(self):
        with patch.object(module.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "no identity found")) as runner, \
             patch.object(module.time, "sleep") as sleeper, contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(subprocess.CalledProcessError):
                module.sign(self.arguments)
            self.assertEqual(runner.call_count, 1)
            sleeper.assert_not_called()

    def test_persistent_timestamp_outage_fails_after_five_attempts(self):
        with patch.object(module.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "The timestamp service is not available.")) as runner, \
             patch.object(module.time, "sleep"), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(subprocess.CalledProcessError):
                module.sign(self.arguments)
            self.assertEqual(runner.call_count, 5)

    def test_hung_service_can_recover(self):
        runner, _ = self.invoke([subprocess.TimeoutExpired("codesign", 120), subprocess.CompletedProcess([], 0, "signed")])
        self.assertEqual(runner.call_count, 2)

    def test_timestamp_cannot_be_disabled(self):
        with patch.object(module.subprocess, "run") as runner:
            for arguments in [[], ["--sign", "Fixture"], [*self.arguments, "--timestamp=none"]]:
                with self.assertRaises(ValueError):
                    module.sign(arguments)
            runner.assert_not_called()


if __name__ == "__main__":
    unittest.main()
