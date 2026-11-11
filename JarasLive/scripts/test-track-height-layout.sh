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
start=grid.index('                                        let heightRatio = slot.height')
end=grid.index('                                            let silenced',start)
mixer='\n@MainActor private func retainedMixerHeights(_ rows: TrackRowLayout, index: Int, slotHeight: CGFloat) -> (CGFloat, CGFloat) {\n'+grid[start:end].replace('slot.height','slotHeight')+'\nreturn (audioHeight, envelopeHeight)\n}\n'
stubs='''import SwiftUI
struct TrackAutomation {
 var enabled = true
 var lanesVisible: Bool? = nil
 var envelopes: [Envelope] = []
 var visibleEnvelopes: [Envelope] { !enabled || lanesVisible == false ? [] : envelopes.filter(\\.visible) }
 struct Envelope { var visible = true }
}
enum TrackKind { case standard, programChange, teleprompt, teleprompt2; var isTeleprompter: Bool { self == .teleprompt || self == .teleprompt2 } }
struct Track { var kind: TrackKind = .standard; var programChangeLaneCount = 1; var automation: TrackAutomation? = nil; var id = UUID(); var heightScale: Double? = nil; var clips: [AudioClip] = [] }
struct AudioClip: Equatable { var id = UUID(); var startTime: Double; var duration: Double; var recordingLane: Int? = nil }
struct Part: Equatable { var id = UUID(); var parentRegionID: UUID? = nil; var startTime: Double; var endTime: Double }
struct TimelineRenderKey: Equatable { let revision: Int; var recordingRevision: Int = 0 }
enum LaneBuildCounter { static var count = 0 }
final class RecordingLaneLayout {
 struct Item { var track: UUID; var clip: AudioClip }
 var items: [UUID: Item] = [:]
 static let shared = RecordingLaneLayout(); var counts: [UUID:Int] = [:]
 func count(for id: UUID, existing: Int) -> Int { max(existing, counts[id] ?? 1) }
}
'''
Path(sys.argv[1]).write_text(stubs+geometry+lanes+cache+rows+mixer+Path('Application/Project/TeleprompterSettings.swift').read_text()+Path('Apple/Shared/DAWRemoteProtocol.swift').read_text()+'\n'+Path('Tests/Apple/TrackHeightLayoutTests.swift').read_text())
PY
swiftc -Onone -g -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
