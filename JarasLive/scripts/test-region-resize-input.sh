#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-region-input.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
cp Tests/Apple/RegionResizeInputTests.swift "$test_dir/main.swift"
swiftc -swift-version 5 Application/Project/OutputPatch.swift Application/Project/NativeFXSettings.swift Application/Project/TrackRouting.swift Application/Project/ProjectModels.swift Application/Project/TimelineTempo.swift Apple/Shared/Theme.swift Apple/Shared/NativeTooltips.swift Apple/Shared/RightClickRouting.swift Apple/Shared/RegionEditor.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
