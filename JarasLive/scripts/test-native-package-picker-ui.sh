#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
simulator="${1:?Pass the UDID of a booted iPad simulator}"
picker_ui_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-native-picker-ui.XXXXXX")"
trap 'rm -rf "$picker_ui_dir"' EXIT
python3 scripts/native-package-picker-fixture.py "$picker_ui_dir"
xcodebuild -project "$picker_ui_dir/Fixture.xcodeproj" -scheme Fixture \
    -destination "platform=iOS Simulator,id=$simulator" -derivedDataPath "$picker_ui_dir/derived" \
    -jobs 2 -parallel-testing-enabled NO -collect-test-diagnostics never ONLY_ACTIVE_ARCH=YES test "${@:2}"
