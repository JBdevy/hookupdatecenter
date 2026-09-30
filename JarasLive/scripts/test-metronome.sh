#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-metronome.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
clang++ -std=c++17 -fobjc-arc Tests/Apple/MetronomeRenderTests.mm -framework AVFoundation -framework Foundation -framework CoreMIDI -framework AudioToolbox -o "$test_dir/test"
"$test_dir/test"
