#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-midi-editor.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
python3 - "$build_dir" <<'PY'
from pathlib import Path
import sys
s=Path('Apple/Shared/MIDIEditor.swift').read_text();s=s[s.index('private final class MIDIPianoScrollView:'):s.index('\n#endif',s.index('private final class MIDIPianoScrollView:'))].replace('private final class MIDIPianoScrollView:', 'final class MIDIPianoScrollView:')
grid=Path('Apple/Shared/TimelineGridView.swift').read_text()
s='private enum MIDIPianoLimits { static let zoom = 24.0...360.0; static let height = 10.0...42.0 }\n'+s
s=grid[grid.index('enum TimelineZoomLimits {'):grid.index('enum TimelineTrackHeightLimits {')]+s
p=Path(sys.argv[1]);gate=Path('Apple/Shared/NativeTimelineInputGate.swift').read_text()
gate=gate[gate.index('protocol NativeTimelineInputObserver:'):gate.index('struct NativeTimelineModalGate:')]
p.joinpath('canvas.swift').write_text('import AppKit\nimport SwiftUI\n'+s+'\n'+gate)
p.joinpath('main.swift').write_text(Path('Tests/Apple/MIDIEditorInputTests.swift').read_text())
PY
swiftc -swift-version 5 Application/Project/OutputPatch.swift Application/Project/DrummerPadKit.swift Application/Project/NativeFXSettings.swift Application/Project/TrackRouting.swift Application/Project/MultiLoop.swift Application/Project/TrackAutomation.swift Application/Controls/NativeFXParameter.swift Application/Project/ProjectModels.swift Application/Project/MIDIItem.swift Application/Project/ItemFade.swift Application/Project/ItemFadeCurve.swift Application/Project/TimelineTempo.swift Apple/Shared/Theme.swift Apple/Shared/NativeTooltips.swift "$build_dir/canvas.swift" "$build_dir/main.swift" -o "$build_dir/test"
"$build_dir/test"
