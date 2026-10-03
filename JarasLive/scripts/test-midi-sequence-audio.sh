#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${1:?Provide a local SF2 file for PCM validation}"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-midi-sequence.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
clang++ -O2 -std=c++17 -fobjc-arc -c Apple/Bridge/JarasSoundFont.mm -o "$build_dir/instrument.o"
cp Tests/Apple/MIDISequenceAudioTests.swift "$build_dir/main.swift"
swiftc -swift-version 5 -import-objc-header Apple/Bridge/JarasSoundFont.h "$build_dir/main.swift" "$build_dir/instrument.o" -lc++ -o "$build_dir/test"
"$build_dir/test" "$1"
JARAS_TEST_SAMPLE_RATE=48000 "$build_dir/test" "$1"
