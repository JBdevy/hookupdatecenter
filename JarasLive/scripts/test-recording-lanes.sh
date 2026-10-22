#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-recording-lanes.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
python3 - "$build_dir/Layout.swift" "$build_dir/Rows.swift" <<'PYTHON'
from pathlib import Path
import sys
source = Path('Apple/Shared/LiveRecordingPreview.swift').read_text()
source = source[source.index('@MainActor final class RecordingLaneLayout'):source.index('struct RecordingGridOverlay')]
Path(sys.argv[1]).write_text('import Foundation\nimport Combine\n' + source)
grid = Path('Apple/Shared/TimelineGridView.swift').read_text()
rows = grid[grid.index('@MainActor private struct TrackRowLayout {'):grid.index('\nprivate struct TimelineHeader:')]
Path(sys.argv[2]).write_text('import Foundation\n' + rows.replace('@MainActor private struct TrackRowLayout', '@MainActor struct TrackRowLayout'))
PYTHON
swiftc -swift-version 5 Application/Controls/NativeFXParameter.swift Application/Project/{ProjectModels,TrackAutomation,ItemFade,ItemFadeCurve,MIDIItem,ProjectDocumentCodec,ProjectDocumentAppearance,MultiLoop,AudioFileRead,TimelineTempo,OutputPatch,TrackRouting,ClipRepetition,NativeFXSettings,RecordingOverview,StemProjectImporter,MediaFileNames,HookImportRules}.swift "$build_dir/Layout.swift" "$build_dir/Rows.swift" Tests/Apple/RecordingLaneLayoutTests.swift -o "$build_dir/test"
"$build_dir/test"
