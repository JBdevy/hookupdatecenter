#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-track-height-layout.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
models=Path('Application/Project/ProjectModels.swift').read_text()
grid=Path('Apple/Shared/TimelineGridView.swift').read_text()
geometry=models[models.index('public enum TrackHeightGeometry'):models.index('public struct TrackLinkOriginal')]
lanes=models[models.index('public struct TrackLanes'):models.index('public enum TrackKind')]
lanes=lanes.replace('public ', '').replace('init(track: Track) {', 'init(track: Track) { LaneBuildCounter.count += 1')
cache=grid[grid.index('@MainActor private final class TrackLayoutCache'):grid.index('@MainActor private final class RegionOverlapCache')]
row_start=grid.index('@MainActor private struct TrackRowLayout')
rows=grid[row_start:grid.index('private struct TimelineHeader:', row_start)]
stubs='''import SwiftUI
struct Track { var id = UUID(); var heightScale: Double? = nil; var clips: [AudioClip] = [] }
struct AudioClip { var id = UUID(); var startTime: Double; var duration: Double; var recordingLane: Int? = nil }
struct Part { var id = UUID(); var parentRegionID: UUID? = nil; var startTime: Double; var endTime: Double }
struct TimelineRenderKey: Equatable { let revision: Int }
enum LaneBuildCounter { static var count = 0 }
final class RecordingLaneLayout {
 static let shared = RecordingLaneLayout(); var counts: [UUID:Int] = [:]
 func count(for id: UUID, existing: Int) -> Int { max(existing, counts[id] ?? 1) }
}
'''
Path(sys.argv[1]).write_text(stubs+geometry+lanes+cache+rows+Path('Application/Project/TeleprompterSettings.swift').read_text()+Path('Apple/Shared/DAWRemoteProtocol.swift').read_text()+'\n'+Path('Tests/Apple/TrackHeightLayoutTests.swift').read_text())
PY
swiftc -O -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
