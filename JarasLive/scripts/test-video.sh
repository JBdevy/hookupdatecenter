#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${JARAS_TEST_VIDEO:?Set JARAS_TEST_VIDEO to a local MOV/MP4 fixture}"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-video.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
cp Tests/Apple/VideoPlaybackTests.swift "$test_dir/main.swift"
swiftc -swift-version 5 Application/Project/{ProjectModels,TimelineTempo,OutputPatch,TrackRouting,NativeFXSettings,StemProjectImporter,HookImportRules}.swift Apple/Shared/ProjectionWindow.swift Apple/Shared/VideoPlayback.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
