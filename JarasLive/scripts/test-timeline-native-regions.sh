#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -e /tmp/catlive-perf-measurement.lock ]]; then
  echo "Performance measurement is active; native region compilation deferred." >&2
  exit 2
fi
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-native-regions.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/TimelineGridView.swift').read_text()
start = source.index('/// Region commands are structural;')
end = source.index('@MainActor private struct NativeTimelineBaseStyle', start)
probes = '''
extension NativeTimelineRegionTargetsView {
    func viewForTest(_ id: UUID) -> RegionRightClickView? { mounted[id]?.view }
    func selectionForTest(_ id: UUID) -> CAShapeLayer? { mounted[id]?.selection }
    var activeDragsForTest: Set<UUID> { activeDrags }
    var orderForTest: [UUID] { mountedOrder }
}
'''
Path(sys.argv[1], 'main.swift').write_text('import AppKit\nimport SwiftUI\n' + source[start:end] + probes +
    Path('Tests/Apple/TimelineNativeRegionTests.swift').read_text() +
    Path('Tests/Apple/TimelineNativeRegionClippingTests.swift').read_text())
# Expose geometry and count cursor invalidations only in this extracted fixture.
editor = Path('Apple/Shared/RegionEditor.swift').read_text()
editor = editor.replace('    private var projectedRegionRect: CGRect?',
    '    var projectionInvalidationsForTest = 0\n    private var projectedRegionRect: CGRect?', 1)
editor = editor.replace('        if !frameChanged, cursorChanged {',
    '        if !frameChanged, cursorChanged {\n            projectionInvalidationsForTest += 1', 1)
editor += '''
#if os(macOS)
extension RegionRightClickView {
    var logicalRectForTest: CGRect {
        regionRect.offsetBy(dx: -projectedInputBounds.minX, dy: -projectedInputBounds.minY)
    }
    var inputLocalBoundsForTest: CGRect { CGRect(origin: .zero, size: projectedInputBounds.size) }
    func edgeForTest(at x: CGFloat) -> Int { edge(at: x + projectedInputBounds.minX) }
    var hoverGripForTest: CGRect? { gripRect }
    var cursorRectsForTest: [CGRect] {
        let projection = cursorProjection()
        return [projection.left, projection.right].filter { !$0.isNull && !$0.isEmpty }
    }
}
#endif
'''
Path(sys.argv[1], 'RegionEditor.swift').write_text(editor)
PY
swiftc -swift-version 5 -target "$(uname -m)-apple-macos12.0" \
  Application/Project/OutputPatch.swift Application/Project/NativeFXSettings.swift \
  Application/Project/TrackRouting.swift Application/Project/MultiLoop.swift \
  Application/Project/ProjectModels.swift Application/Project/MIDIItem.swift \
  Application/Project/TimelineTempo.swift Apple/Shared/Theme.swift Apple/Shared/NativeTooltips.swift \
  Apple/Shared/NativeTimelineInputGate.swift Apple/Shared/RightClickRouting.swift \
  "$test_dir/RegionEditor.swift" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
