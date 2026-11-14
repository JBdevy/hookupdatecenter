#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-mixer-scroll-distance.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
cp Tests/Apple/MixerScrollDistanceTests.swift "$test_dir/main.swift"
swiftc -swift-version 5 -target "${CATLIVE_TEST_ARCH:-$(uname -m)}-apple-macos12.0" Apple/Shared/NativeTimelineInputGate.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
