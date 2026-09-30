#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-click-tempo.XXXXXX")"
trap 'rm -rf "$dir"' EXIT
cp Tests/Apple/ClickOnsetTests.swift "$dir/main.swift"
swiftc -O -swift-version 5 \
  Application/Project/OutputPatch.swift Application/Project/NativeFXSettings.swift \
  Application/Project/TrackRouting.swift Application/Project/MultiLoop.swift Application/Project/ProjectModels.swift \
  Application/Project/TimelineTempo.swift Application/Project/ClipRepetition.swift \
  Application/Project/ClickTempoDetector.swift Apple/Shared/TimelineAudioWaveform.swift \
  "$dir/main.swift" -o "$dir/test"
"$dir/test"
