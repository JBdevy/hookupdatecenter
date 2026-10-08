#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-waveform-block-lookup.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
cat Application/Project/AudioFileRead.swift Apple/Shared/TimelineAudioWaveform.swift Tests/Apple/TimelineWaveformBlockLookupTests.swift > "$test_dir/main.swift"
swiftc -O -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
