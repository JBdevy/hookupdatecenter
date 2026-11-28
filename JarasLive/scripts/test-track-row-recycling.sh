#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-track-recycling.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source=Path('Apple/Shared/TrackMixerRow.swift').read_text()
start=source.index('struct TrackControlSelectionExclusion:')
end=source.index('\n#endif',start)
title_start=source.index('private struct TrackDragTitle:')
title_end=source.index('\n#endif',title_start)
wheel=Path('Apple/Shared/TimelineWheelInput.swift').read_text()
height=wheel[wheel.index('struct TimelineTrackHeightResizeInput:'):wheel.index('struct TimelineWheelInput:')]
models=Path('Application/Project/ProjectModels.swift').read_text()
geometry=models[models.index('public enum TrackHeightGeometry'):models.index('public struct TrackLinkOriginal')]
stubs='''import SwiftUI
import AppKit
final class ControlMappings { static let shared = ControlMappings(); var editing: String? }
final class NativeVerticalTrackMeterView: NSView {}
final class TrackMixerNativeControlView: NSView {
    func addControlArea(_ view: NSView) {}
    func removeControlArea(_ view: NSView) {}
}
private final class TrackReorderState: ObservableObject {
    static let shared = TrackReorderState()
    var active = false
    var source: TrackDragSource?
    private(set) var starts = 0
    func begin(track: UUID) { starts += 1; active = true }
    func finish() { active = false }
}
'''
scroll=Path('Apple/Shared/GridScrollView.swift').read_text()
edge=scroll[scroll.index('@MainActor final class NativeDragEdgeScroll'):scroll.index('\n#endif',scroll.index('@MainActor final class NativeDragEdgeScroll'))]
selection_start=source.index('struct EditorSelectionArea: NSViewRepresentable')
selection=source[selection_start:source.index('\n#endif',selection_start)]
typography=Path('Apple/Shared/Theme.swift').read_text().split('// App-owned typography.')[1]
def declaration(text, marker):
    begin = text.index(marker)
    return text[begin:text.index('\n}', begin) + 2]
tool=declaration(Path('Apple/Shared/TransportView.swift').read_text(), 'enum ProGridTool:')
# Executing project commands is outside this row's input-routing test.
tool=tool[:tool.index('    @MainActor func apply(')] + tool[tool.index('    var symbol:'):]
menu_types=[declaration(models, 'public enum TrackKind:'), declaration(models, 'public enum TrackMixerComponent:'),
            declaration(source, 'private enum HozMixerComponent:'), declaration(source, '@MainActor private func trackComponentCheckboxes('), tool]
Path(sys.argv[1]).write_text('\n'.join([stubs,'// App-owned typography.'+typography,*menu_types,geometry,height,edge,
                                       selection,source[start:end],source[title_start:title_end],Path('Tests/Apple/TrackRowRecyclingTests.swift').read_text()]))
PY
swiftc -swift-version 5 Apple/Shared/NativeTooltips.swift Apple/Shared/NativeTimelineInputGate.swift Apple/Shared/RightClickRouting.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
