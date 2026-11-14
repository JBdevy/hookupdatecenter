#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-converter-sharing.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
clang++ -std=c++17 -O2 -fobjc-arc -fsanitize=address,undefined \
 Tests/Apple/SharedStretchConverterTests.mm -framework AVFoundation -framework Foundation \
 -framework AudioToolbox -framework Accelerate -o "$test_dir/test"
ASAN_OPTIONS=detect_leaks=0 "$test_dir/test"
