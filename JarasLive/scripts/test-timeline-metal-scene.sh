#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-metal-scene.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
cp Tests/Apple/TimelineMetalSceneTests.swift "$test_dir/main.swift"
swiftc Apple/Shared/TimelineRenderDiagnostics.swift -O -swift-version 5 \
  Application/Project/OutputPatch.swift Application/Project/NativeFXSettings.swift \
  Application/Project/TrackRouting.swift Application/Project/MultiLoop.swift \
  Application/Project/ProjectModels.swift Application/Project/MIDIItem.swift Application/Project/TimelineTempo.swift \
  Application/Project/ClipRepetition.swift Application/Project/AudioFileRead.swift Apple/Shared/TimelineAudioWaveform.swift \
  Apple/Shared/MetalWaveformRenderer.swift Apple/Shared/TimelineMetalWaveforms.swift \
  "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
