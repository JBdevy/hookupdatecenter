#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-track-controls.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
clang++ -O2 -std=c++17 -fobjc-arc -c Apple/Bridge/JarasEffects.mm -o "$build_dir/effects.o"
cp Tests/Apple/TrackControlsPerformanceTests.swift "$build_dir/main.swift"
swiftc -O -swift-version 5 -import-objc-header Apple/Bridge/JarasEffects.h "$build_dir/main.swift" "$build_dir/effects.o" -framework Accelerate -lc++ -o "$build_dir/test"
"$build_dir/test" --separate
"$build_dir/test"
"$build_dir/test"
"$build_dir/test" --separate
