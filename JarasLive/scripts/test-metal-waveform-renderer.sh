#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-metal-waveform.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
cp Tests/Apple/MetalWaveformRendererTests.swift "$test_dir/main.swift"
swiftc Apple/Shared/TimelineRenderDiagnostics.swift "${JARAS_TEST_OPTIMIZATION:--O}" -swift-version 5 -target "$(uname -m)-apple-macos13.0" Application/Project/AudioFileRead.swift Apple/Shared/TimelineAudioWaveform.swift Apple/Shared/MetalWaveformRenderer.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
