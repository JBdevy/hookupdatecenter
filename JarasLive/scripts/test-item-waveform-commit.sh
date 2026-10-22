#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-waveform-commit.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
swiftc -O -swift-version 5 -parse-as-library \
 Application/Project/OutputPatch.swift Application/Project/NativeFXSettings.swift \
 Application/Project/TrackRouting.swift Application/Project/MultiLoop.swift \
 Application/Project/TrackAutomation.swift Application/Controls/NativeFXParameter.swift \
 Application/Project/ProjectModels.swift Application/Project/MIDIItem.swift \
 Application/Project/ItemFade.swift Application/Project/ItemFadeCurve.swift Application/Project/TimelineTempo.swift \
 Apple/Shared/ItemWaveformPreview.swift Tests/Apple/ItemWaveformCommitTests.swift -o "$check_dir/test"
"$check_dir/test"
