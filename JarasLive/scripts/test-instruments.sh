#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-instruments.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
font="${1:-${JARAS_TEST_SF2:-}}"
if [[ -z "$font" ]]; then
    font="$build_dir/test-tone.sf2"
    python3 scripts/generate-test-sf2.py "$font"
fi
clang++ -O2 -std=c++17 -mmacosx-version-min=12.0 -fobjc-arc -c Apple/Bridge/JarasSoundFont.mm -o "$build_dir/instrument.o"
cp Tests/Apple/InstrumentRenderTests.swift "$build_dir/main.swift"
swiftc -target "$(uname -m)-apple-macos12.0" -swift-version 5 -import-objc-header Apple/Bridge/JarasSoundFont.h "$build_dir/main.swift" "$build_dir/instrument.o" -lc++ -o "$build_dir/test"
"$build_dir/test" "$font"
JARAS_TEST_SAMPLE_RATE=48000 "$build_dir/test" "$font"
