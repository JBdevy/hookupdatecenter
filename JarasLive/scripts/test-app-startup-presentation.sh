#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-startup.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/StartupPresentation.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/AppContainer.swift').read_text()
helper = source[source.index('enum AppStartupPresentation'):source.index('@MainActor final class AppContainer')]
helper = helper.replace('ProcessInfo.processInfo.systemUptime', 'AppStartupTestClock.now').replace('Task.sleep(nanoseconds:', 'AppStartupTestClock.sleep(nanoseconds:')
Path(sys.argv[1]).write_text('import Foundation\nimport AppKit\n' + helper)
PY
swiftc -swift-version 5 -parse-as-library "$test_dir/StartupPresentation.swift" Tests/Apple/AppStartupTestClock.swift Tests/Apple/AppStartupPresentationTests.swift -o "$test_dir/test"
"$test_dir/test"

# Control playback completion without requiring an output device in CI.
# The same production coordinator must hold graph activation, remain
# cancellable, and admit later project openings without replaying the sound.
python3 - "$test_dir/StartupSound.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/AppContainer.swift').read_text()
helper = source[source.index('enum AppStartupPresentation'):source.index('@MainActor final class AppContainer')]
helper = helper.replace('ProcessInfo.processInfo.systemUptime', 'AppStartupTestClock.now').replace('Task.sleep(nanoseconds:', 'AppStartupTestClock.sleep(nanoseconds:')
Path(sys.argv[1]).write_text('import Foundation\n' + helper.replace('NSSound', 'ControlledStartupSound'))
PY
touch "$test_dir/StartupSound.wav"
swiftc -swift-version 5 -parse-as-library "$test_dir/StartupSound.swift" Tests/Apple/AppStartupTestClock.swift Tests/Apple/AppStartupSoundTests.swift -o "$test_dir/sound-test"
for scenario in completion cancelled disabled failed timeout; do
    "$test_dir/sound-test" "$scenario"
done
