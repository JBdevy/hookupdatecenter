#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
simulator="${1:?Pass the UDID of a booted iPad simulator}"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-ipad-track-controls.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 scripts/ipad-track-controls-fixture.py "$test_dir"
xcodebuild -project "$test_dir/Fixture.xcodeproj" -scheme Fixture \
    -destination "platform=iOS Simulator,id=$simulator" -derivedDataPath "$test_dir/derived" \
    -jobs 2 ONLY_ACTIVE_ARCH=YES test
