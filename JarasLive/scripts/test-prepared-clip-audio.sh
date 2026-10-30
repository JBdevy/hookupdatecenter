#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
prepared_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-prepared-clip.XXXXXX")"
trap 'rm -rf "$prepared_test_dir"' EXIT
clang++ -std=c++17 -O2 -fobjc-arc -c Apple/Bridge/JarasEffects.mm -o "$prepared_test_dir/effects.o"
swiftc -swift-version 5 -import-objc-header Apple/Bridge/JarasEffects.h \
  Tests/Apple/PreparedClipAudioTests.swift "$prepared_test_dir/effects.o" \
  -framework AVFoundation -framework AudioToolbox -framework Accelerate -framework Foundation -lc++ \
  -o "$prepared_test_dir/test"
"$prepared_test_dir/test"
