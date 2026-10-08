#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# This explicit integration fixture moves the real pointer in its own window.
# It requires an interactive macOS session and must not overlap a benchmark.
if [[ -e /tmp/catlive-perf-measurement.lock ]]; then
  echo "Performance measurement is active; cursor fixture deferred." >&2
  exit 2
fi
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-workspace-cursors.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PYFIXTURE'
from pathlib import Path
import os, sys
repo = Path.cwd()
candidate = Path(os.environ.get('CATLIVE_WORKSPACE_CURSOR_SOURCE', 'Apple/Shared/GridScrollView.swift'))
out = Path(sys.argv[1])
fx = (repo/'Apple/Shared/FXEditor.swift').read_text()
text = (repo/'Apple/Shared/TextItemEditor.swift').read_text()
region = (repo/'Apple/Shared/RegionEditor.swift').read_text()
(out/'environment.swift').write_text(fx[:fx.index('enum FXModelLookup')] + text[:text.index('/// The draft')] + region[region.index('/// Immutable menu target:'):])
s = (repo/'Apple/Shared/TimelineGridView.swift').read_text()
a = s.index('struct MixerResizeHandle:')
(out/'divider.swift').write_text('import SwiftUI\nimport AppKit\n' + s[a:s.index('\n#endif', a)])
s = candidate.read_text()
assert 'workspaceWindowBecameKey' in s, 'Workspace arrow is not installed; set CATLIVE_WORKSPACE_CURSOR_SOURCE to the staged candidate for this experiment'
s = s.replace('private final class WorkspaceSplitView<', 'enum WorkspaceArrowTestSwitch { static var enabled = false; static var registrations = 0; static var registeredRects: [NSRect] = []; static var resets = 0; static var discards = 0; static var keyNotifications = 0 }\nprivate final class WorkspaceSplitView<', 1)
a = s.index('private final class WorkspaceSplitView')
b = s.index('/// Keep mixer controls', a)
x = s[a:b].replace('    override func resetCursorRects() {\n', '    override func discardCursorRects() { WorkspaceArrowTestSwitch.discards += 1; super.discardCursorRects() }\n    override func resetCursorRects() {\n        WorkspaceArrowTestSwitch.resets += 1\n        guard WorkspaceArrowTestSwitch.enabled else { return }\n', 1)
x = x.replace('        addCursorRect(rect, cursor: .arrow)', '        WorkspaceArrowTestSwitch.registrations += 1\n        WorkspaceArrowTestSwitch.registeredRects.append(rect)\n        addCursorRect(rect, cursor: .arrow)', 1)
x = x.replace('    @objc private func workspaceWindowBecameKey(_ notification: Notification) {', '    @objc private func workspaceWindowBecameKey(_ notification: Notification) {\n        WorkspaceArrowTestSwitch.keyNotifications += 1', 1)
(out/'GridScrollView.swift').write_text(s[:a] + x + s[b:])

(out/'main.swift').write_text((repo/'Tests/Apple/WorkspaceCursorPriorityTests.swift').read_text())
PYFIXTURE
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos12.0"     Apple/Shared/NativeTimelineInputGate.swift "$test_dir/GridScrollView.swift"     "$test_dir/environment.swift" "$test_dir/divider.swift" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test" "$@"
