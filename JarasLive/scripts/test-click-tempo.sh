#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-click-tempo.XXXXXX")"
trap 'rm -rf "$dir"' EXIT
sources=(
  Application/Project/OutputPatch.swift Application/Project/DrummerPadKit.swift Application/Project/NativeFXSettings.swift
  Application/Project/TrackRouting.swift Application/Project/MultiLoop.swift Application/Project/TrackAutomation.swift
  Application/Controls/NativeFXParameter.swift Application/Project/ProjectModels.swift Application/Project/MIDIItem.swift
  Application/Project/ItemFade.swift Application/Project/ItemFadeCurve.swift Application/Project/TimelineTempo.swift
  Application/Project/ClipRepetition.swift Application/Project/ClickTempoDetector.swift
)
cp Tests/Apple/ClickOnsetTests.swift "$dir/main.swift"
swiftc Application/Project/LinkedStemMedia.swift -O -swift-version 5 "${sources[@]}" Application/Project/AudioFileRead.swift Apple/Shared/TimelineAudioWaveform.swift \
  "$dir/main.swift" -o "$dir/test"
"$dir/test"
swiftc -O -swift-version 5 -parse-as-library "${sources[@]}" Apple/Shared/SelectionTempoAnalysis.swift \
  Tests/Apple/SelectionTempoAnalysisTests.swift -o "$dir/selection"
"$dir/selection"
