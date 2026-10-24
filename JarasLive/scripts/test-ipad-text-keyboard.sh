#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
simulator="${1:?Pass the UDID of a booted iPad simulator}"
keyboard_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-ipad-keyboard.XXXXXX")"
trap 'rm -rf "$keyboard_test_dir"' EXIT
python3 scripts/ipad-text-keyboard-fixture.py "$keyboard_test_dir"
xcodebuild -project "$keyboard_test_dir/Fixture.xcodeproj" -scheme Fixture \
    -destination "platform=iOS Simulator,id=$simulator" -derivedDataPath "$keyboard_test_dir/derived" \
    -jobs 2 -collect-test-diagnostics never ONLY_ACTIVE_ARCH=YES test
