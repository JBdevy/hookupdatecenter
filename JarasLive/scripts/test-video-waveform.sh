#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
video_wave_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-video-waveform.XXXXXX")"
trap 'rm -rf "$video_wave_test_dir"' EXIT
cp Tests/Apple/VideoWaveformTests.swift "$video_wave_test_dir/main.swift"
swiftc -O -swift-version 5 Application/Project/AudioFileRead.swift Apple/Shared/TimelineAudioWaveform.swift "$video_wave_test_dir/main.swift" -o "$video_wave_test_dir/test"
"$video_wave_test_dir/test"
