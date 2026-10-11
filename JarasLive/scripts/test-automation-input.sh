#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/catlive-env-input.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
python3 - "$build_dir" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/AutomationEditor.swift').read_text()
source = source[source.index('@MainActor final class AutomationLaneView:'):source.rindex('#endif')]
directory = Path(sys.argv[1])
(directory/'view.swift').write_text('import AppKit\nimport SwiftUI\n'+source)
(directory/'main.swift').write_text(Path('Tests/Apple/AutomationLaneInputTests.swift').read_text())
PY
swiftc -swift-version 5 Application/Project/OutputPatch.swift Application/Project/NativeFXSettings.swift Application/Project/TrackRouting.swift Application/Project/MultiLoop.swift Application/Project/TrackAutomation.swift Application/Controls/NativeFXParameter.swift Application/Project/ProjectModels.swift Application/Project/MIDIItem.swift Application/Project/TimelineTempo.swift Apple/Shared/Theme.swift Apple/Shared/NativeTooltips.swift Apple/Shared/NativeTimelineInputGate.swift "$build_dir/view.swift" "$build_dir/main.swift" -o "$build_dir/test"
"$build_dir/test"
