#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
connection_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-output-connection.XXXXXX")"
trap 'rm -rf "$connection_test_dir"' EXIT
clang++ -std=c++17 -fobjc-arc -I Apple/Bridge Tests/Apple/AudioOutputConnectionTests.mm Apple/Bridge/JarasEffects.mm -framework AVFoundation -framework AudioToolbox -framework Accelerate -framework Foundation -o "$connection_test_dir/test"
"$connection_test_dir/test"
