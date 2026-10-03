#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-folder-waveform.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
cp Tests/Apple/FolderWaveformTests.swift "$test_dir/main.swift"
swiftc "${JARAS_TEST_OPTIMIZATION:--O}" -swift-version 5 \
  Application/Project/OutputPatch.swift Application/Project/NativeFXSettings.swift \
  Application/Project/TrackRouting.swift Application/Project/MultiLoop.swift \
  Application/Project/ProjectModels.swift Application/Project/MIDIItem.swift Application/Project/TimelineTempo.swift \
  Application/Project/ClipRepetition.swift Application/Project/AudioFileRead.swift Apple/Shared/TimelineAudioWaveform.swift \
  Apple/Shared/FolderWaveformCache.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
