#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-item-channels.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
clang++ -std=c++17 -fobjc-arc -c Apple/Bridge/JarasEffects.mm -o "$test_dir/effects.o"
cp Tests/Apple/ItemChannelModeTests.swift "$test_dir/main.swift"
swiftc -swift-version 5 -import-objc-header Apple/Bridge/JarasEffects.h "$test_dir/main.swift" "$test_dir/effects.o" -framework Accelerate -lc++ -o "$test_dir/test"
"$test_dir/test"
