#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-waveform-vertices.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
cat Apple/Shared/TimelineAudioWaveform.swift Tests/Apple/TimelineWaveformVertexTests.swift > "$test_dir/main.swift"
swiftc -O -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
