#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-timer-control.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source=Path('Apple/Shared/ControlMappings.swift').read_text()
start=source.index('#if os(macOS)\nprivate struct MappingClickAnchor')
tests=Path('Tests/Apple/TeleprompterTimerControlTests.swift').read_text().replace('import AppKit\n','',1)
Path(sys.argv[1]).write_text('import SwiftUI\nimport AppKit\n'+source[start:]+'\n@MainActor func runTimerControlTests() {\n'+tests+'\n}\nTask { @MainActor in runTimerControlTests(); exit(0) }\nRunLoop.main.run()\n')
PY
swiftc -swift-version 5 Application/Project/OutputPatch.swift Application/Project/NativeFXSettings.swift Application/Project/TrackRouting.swift Application/Project/MultiLoop.swift Application/Project/ProjectModels.swift Application/Project/TimelineTempo.swift Application/Project/TeleprompterTimer.swift Apple/Shared/Theme.swift Apple/Shared/NativeTooltips.swift Apple/Shared/RightClickRouting.swift Apple/Shared/TeleprompterTimerController.swift Apple/Shared/TeleprompterTimerControl.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
