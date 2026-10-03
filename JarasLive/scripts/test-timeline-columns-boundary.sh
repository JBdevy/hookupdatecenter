#!/bin/bash
set -euo pipefail
cd "${CATLIVE_BOUNDARY_REPO:-$(dirname "$0")/..}"
if [[ -e /tmp/catlive-perf-measurement.lock ]]; then
  echo "Performance measurement is active; boundary compilation deferred." >&2
  exit 2
fi
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-columns-boundary-test.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import os, sys
grid = Path(os.environ.get('CATLIVE_BOUNDARY_GRID', 'Apple/Shared/GridScrollView.swift')).read_text()
host = grid[grid.index('protocol SidebarResizeLayoutBoundary:'):grid.index('private struct WorkspaceHostingIdentity:')]
actions = grid[grid.index('private final class GridHostedActions'):grid.index('/// Explicit document geometry')]
native = grid[grid.index('struct NativeTimelineColumns<'):grid.index('private struct NativeGridScroll<')]
document = grid[grid.index('/// Explicit document geometry'):grid.index('final class GridNativeScrollView:')]
fx = Path('Apple/Shared/FXEditor.swift').read_text().split('enum FXModelLookup')[0]
text = Path('Apple/Shared/TextItemEditor.swift').read_text().split('/// The draft stays')[0]
region = Path('Apple/Shared/RegionEditor.swift').read_text()
start = region.index('struct TrackDetailsEditRequest:')
end = region.index('\n}\n', region.index('extension EnvironmentValues', start)) + 3
environment = fx + text + region[start:end]
diagnostics = '''
enum TimelineLayoutDiagnostics {
    static var roots: [String: Int] = [:]
    static var layouts: [String: Int] = [:]
    final class Profile {
        let role: String
        init(_ role: String) { self.role = role }
        func beginLayout(_ view: NSView) -> Double { TimelineLayoutDiagnostics.layouts[role, default: 0] += 1; return 0 }
        func endLayout(_ value: Double) {}
        func rootAssigned(_ view: NSView) { TimelineLayoutDiagnostics.roots[role, default: 0] += 1 }
        func sizeChanged(_ view: NSView, from old: NSSize, to new: NSSize) {}
    }
    static func make(_ role: String) -> Profile? { Profile(role) }
}
'''
tests = Path(os.environ.get('CATLIVE_BOUNDARY_TEST', 'Tests/Apple/TimelineColumnsBoundaryTests.swift')).read_text()
Path(sys.argv[1]).write_text('import SwiftUI\nimport AppKit\n' + environment + diagnostics + host + actions + document + native + tests)
PY
swiftc -swift-version 5 -target "$(uname -m)-apple-macos12.0" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
