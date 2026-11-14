#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
buffered_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-buffered-output.XXXXXX")"
trap 'rm -rf "$buffered_test_dir"' EXIT
clang++ -std=c++17 -O2 -fobjc-arc -fsanitize=address,undefined \
  Tests/Apple/BufferedAudioOutputTests.mm -framework AVFoundation -framework Foundation \
  -framework AudioToolbox -framework Accelerate -o "$buffered_test_dir/test"
ASAN_OPTIONS=detect_leaks=0 "$buffered_test_dir/test"
