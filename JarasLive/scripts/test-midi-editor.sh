#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-midi-editor.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
python3 - "$build_dir" <<'PY'
from pathlib import Path
import sys
s=Path('Apple/Shared/MIDIEditor.swift').read_text();s=s[s.index('final class MIDIPianoCanvas:'):s.rindex('#endif')]
p=Path(sys.argv[1]);p.joinpath('canvas.swift').write_text('import AppKit\nimport SwiftUI\n'+s)
p.joinpath('main.swift').write_text(Path('Tests/Apple/MIDIEditorInputTests.swift').read_text())
PY
swiftc -swift-version 5 Application/Project/OutputPatch.swift Application/Project/NativeFXSettings.swift Application/Project/TrackRouting.swift Application/Project/MultiLoop.swift Application/Project/ProjectModels.swift Application/Project/MIDIItem.swift Application/Project/TimelineTempo.swift Apple/Shared/Theme.swift "$build_dir/canvas.swift" "$build_dir/main.swift" -o "$build_dir/test"
"$build_dir/test"
