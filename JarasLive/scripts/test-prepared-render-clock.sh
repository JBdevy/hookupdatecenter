#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
render_clock_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-render-clock.XXXXXX")"
trap 'rm -rf "$render_clock_dir"' EXIT
clang++ -std=c++17 -O2 -fobjc-arc -fsanitize=address,undefined \
  Tests/Apple/PreparedRenderClockTests.mm -framework AVFoundation -framework Foundation \
  -framework AudioToolbox -framework Accelerate -o "$render_clock_dir/test"
ASAN_OPTIONS=detect_leaks=0 "$render_clock_dir/test"
