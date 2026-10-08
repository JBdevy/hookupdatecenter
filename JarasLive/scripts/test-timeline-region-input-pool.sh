#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -e /tmp/catlive-perf-measurement.lock ]]; then
  echo "Performance measurement is active; region input pool test deferred." >&2
  exit 2
fi
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-region-input-pool.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
root=Path.cwd()
p=Path(sys.argv[1])
s=(root/'Apple/Shared/TimelineGridView.swift').read_text()
grid=s[s.index('@MainActor private struct NativeTimelineRegionTarget {'):s.index('@MainActor private struct NativeTimelineBaseStyle')]
e=(root/'Apple/Shared/RegionEditor.swift').read_text()
editor=e[e.index('struct RegionRightClick: NSViewRepresentable'):e.index('struct MarkerEditAnchor:')]
editor=editor.replace('final class RegionRightClickView: NSView, NativeTimelineInputObserver {','''final class RegionRightClickView: NSView, NativeTimelineInputObserver {
    override init(frame: NSRect) { RegionPoolProbe.created += 1; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); RegionPoolProbe.treeChanges += 1 }
''',1)
# Exercise the actual menu reservation/defer without displaying UI. This helper
# also avoids changing the user's global cursor during the isolated tests.
editor=editor.replace('NSMenu.popUpContextMenu(regionMenu(), with: event, for: self)', 'RegionPoolProbe.menuBody?(self, regionMenu())',1)
editor=editor.replace('if NSCursor.current !== cursor { cursor.set() }','_ = cursor')
gate=(root/'Apple/Shared/NativeTimelineInputGate.swift').read_text()
gate=gate[gate.index('protocol NativeTimelineInputObserver:'):gate.index('struct NativeTimelineModalGate:')]
probes='''
private extension NativeTimelineRegionTargetsView {
    var activeForTest: [UUID: RegionRightClickView] { mounted.mapValues { $0.view } }
    var idleForTest: [RegionRightClickView] { inactive.map { $0.view } }
    var selectionForTest: [UUID: CAShapeLayer] { mounted.mapValues { $0.selection } }
}
'''
(p/'main.swift').write_text('import AppKit\nimport SwiftUI\nprivate enum JarasLocalization { static func string(_ s: String) -> String { s } }\n'+gate+'\n'+editor+'\n'+grid+'\n'+probes+'\n'+(root/'Tests/Apple/TimelineRegionInputPoolTests.swift').read_text())

PY
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos12.0" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
