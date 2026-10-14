#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
driver_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-mobile-driver.XXXXXX")"
trap 'rm -rf "$driver_test_dir"' EXIT
clang++ -std=c++17 -fobjc-arc -Wno-deprecated-declarations -I Apple/Bridge Tests/Apple/MobileAudioDriverTests.mm Apple/Bridge/JarasEffects.mm Apple/Bridge/JarasTimecode.mm -framework AVFoundation -framework AudioToolbox -framework Accelerate -framework Foundation -framework CoreMIDI -o "$driver_test_dir/test"
"$driver_test_dir/test"
