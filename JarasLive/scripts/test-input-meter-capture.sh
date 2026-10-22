#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
meter_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-input-meter.XXXXXX")"
trap 'rm -rf "$meter_test_dir"' EXIT
# Use the production ring itself; MP3 encoding is unrelated to live input.
python3 - "$meter_test_dir/Capture.mm" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Bridge/JarasRecording.mm').read_text()
ring = source[source.index('@implementation JarasCaptureRing'):source.index('@implementation JarasMP3Encoder')]
headers = '#import <AVFoundation/AVFoundation.h>\n#import "JarasRecording.h"\n#include <atomic>\n#include <vector>\n#include <algorithm>\n#include <thread>\n#include <memory>\n#include <cmath>\n'
Path(sys.argv[1]).write_text(headers + ring)
PY
cp Tests/Apple/InputMeterCaptureTests.swift "$meter_test_dir/main.swift"
if [[ -n "${CATLIVE_IOS_SIMULATOR:-}" ]]; then
    meter_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
    compile=(xcrun --sdk iphonesimulator clang++ -target arm64-apple-ios16.0-simulator -isysroot "$meter_sdk")
    swift=(xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios16.0-simulator -sdk "$meter_sdk")
    run=(xcrun simctl spawn "$CATLIVE_IOS_SIMULATOR")
else
    compile=(clang++)
    swift=(swiftc)
    run=()
fi
"${compile[@]}" -std=c++17 -fobjc-arc -I Apple/Bridge -c "$meter_test_dir/Capture.mm" -o "$meter_test_dir/capture.o"
"${swift[@]}" -swift-version 5 -import-objc-header Apple/Bridge/JarasRecording.h "$meter_test_dir/main.swift" "$meter_test_dir/capture.o" -lc++ -o "$meter_test_dir/test"
"${run[@]}" "$meter_test_dir/test"
JARAS_TEST_SAMPLE_RATE=48000 SIMCTL_CHILD_JARAS_TEST_SAMPLE_RATE=48000 "${run[@]}" "$meter_test_dir/test"
