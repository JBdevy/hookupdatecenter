#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-timeline-canvas.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" "${1:-baseline}" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/TimelineGridView.swift').read_text()
start = source.index('private struct TimelineCanvasSurface:')
end = source.index('/// Search sorted item boundaries', start)
stubs = '''import SwiftUI
private struct TimelineTileIdentity: Equatable { var revision = 0 }
private struct OpenFXKey: EnvironmentKey { static let defaultValue: (UUID?, String) -> Void = { _,_ in } }
private struct OpenClipFXKey: EnvironmentKey { static let defaultValue: (UUID) -> Void = { _ in } }
private struct EditTextKey: EnvironmentKey { static let defaultValue: (UUID) -> Void = { _ in } }
private struct InputBlockedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
 var openFX: (UUID?, String) -> Void { get { self[OpenFXKey.self] } set { self[OpenFXKey.self] = newValue } }
 var openClipFXChain: (UUID) -> Void { get { self[OpenClipFXKey.self] } set { self[OpenClipFXKey.self] = newValue } }
 var editTextItem: (UUID) -> Void { get { self[EditTextKey.self] } set { self[EditTextKey.self] = newValue } }
 var gridInteractionBlocked: Bool { get { self[InputBlockedKey.self] } set { self[InputBlockedKey.self] = newValue } }
}
'''
surface = source[start:end]
needle = '        Canvas(rendersAsynchronously: !synchronized)'
assert needle in surface, 'Canvas body instrumentation must match production'
surface = surface.replace(needle, '        let _ = recordSurfaceBody(tile)\n        return Canvas(rendersAsynchronously: !synchronized)', 1)
if sys.argv[2] == 'drawing-group':
    surface = surface.replace('''        }
    }
}

private struct ViewportTimelineCanvas''', '''        }.drawingGroup(opaque: false, colorMode: .nonLinear)
    }
}

private struct ViewportTimelineCanvas''', 1)
Path(sys.argv[1]).write_text(stubs + surface + '\n' + Path('Tests/Apple/TimelineCanvasReuseTests.swift').read_text())
PY
swiftc Apple/Shared/TimelineRenderDiagnostics.swift -swift-version 5 Apple/Shared/GridScrollView.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
