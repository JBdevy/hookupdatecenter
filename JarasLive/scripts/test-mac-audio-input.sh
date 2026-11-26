#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
input_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-mac-input.XXXXXX")"
trap 'rm -rf "$input_test_dir"' EXIT
clang++ -std=c++17 -O2 -fobjc-arc -I Apple/Bridge Tests/Apple/MacAudioInputTests.mm \
  -framework AVFoundation -framework AudioToolbox -framework CoreAudio -framework Foundation -o "$input_test_dir/test"
"$input_test_dir/test"
bash scripts/test-recording-input-selection.sh
