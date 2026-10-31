#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-patch-output.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
source=Path('Apple/Shared/TrackMixerRow.swift').read_text()
start=source.index('struct PatchEditor: View')
editor=source[start:source.index('private struct CompactTrackButtonStyle:',start)]
# Geometry probes never intercept input or replace the production actions.
editor=editor.replace('struct PatchEditor: View','private struct PatchEditor: View',1)
editor=editor.replace('.accessibilityLabel("Add output")','.accessibilityLabel("Add output").background(PatchProbe(kind: .add))',1)
editor=editor.replace('.accessibilityLabel("Remove output")\n                            }','.accessibilityLabel("Remove output")\n                            }.background(PatchProbe(kind: .output(slot)))',1)
windows=Path('Apple/Shared/FXWindows.swift').read_text()
start=windows.index('private func workspaceEditorContentSize')
sizing=windows[start:windows.index('/// Editors remain independent',start)]
scale=Path('Apple/Shared/InterfaceScaling.swift').read_text()
start=scale.index('struct InterfaceScaleLayout')
scale=scale[start:scale.index('private struct InterfaceScaleModifier',start)]
Path(sys.argv[1],'main.swift').write_text('\n'.join(['import SwiftUI\nimport AppKit',Path('Application/Project/OutputPatch.swift').read_text(),editor,sizing,scale,Path('Tests/Apple/PatchOutputVisibilityTests.swift').read_text()]))
PY
swiftc -swift-version 5 -target "$(uname -m)-apple-macos12.0" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
