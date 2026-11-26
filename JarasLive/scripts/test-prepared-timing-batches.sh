#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-prepared-timing.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
clang++ -std=c++17 -O1 -fobjc-arc -fsanitize=address,undefined \
  Tests/Apple/PreparedTimingBatchTests.mm -framework AVFoundation -framework Foundation \
  -framework AudioToolbox -framework Accelerate -o "$test_dir/test"
ASAN_OPTIONS=detect_leaks=0 "$test_dir/test"
JARAS_PREPARED_TEST_SOURCE=Tests/Apple/PreparedTimingAudioTests.swift bash scripts/test-prepared-clip-audio.sh
