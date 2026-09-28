#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-timecode-signal.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
clang++ -std=c++17 -fobjc-arc -c Apple/Bridge/JarasTimecode.mm -o "$test_dir/timecode.o"
cp Tests/Apple/TimecodeSignalTests.swift "$test_dir/main.swift"
swiftc -swift-version 5 -import-objc-header Apple/Bridge/JarasTimecode.h "$test_dir/main.swift" "$test_dir/timecode.o" -lc++ -o "$test_dir/test"
"$test_dir/test"
