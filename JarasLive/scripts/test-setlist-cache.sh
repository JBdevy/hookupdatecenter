#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-setlist-cache.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/SongListView.swift').read_text()
cache = 'import SwiftUI\n' + source[source.index('@MainActor private final class SetlistEntryCache'):source.index('struct SongListView: View {')]
test = Path('Tests/Apple/SetlistEntryCacheTests.swift').read_text()
Path(sys.argv[1]).write_text(cache + '\n' + test)
PY
swiftc -swift-version 5 Application/Project/OutputPatch.swift Application/Project/NativeFXSettings.swift Application/Project/TrackRouting.swift Application/Project/MultiLoop.swift Application/Project/TrackAutomation.swift Application/Controls/NativeFXParameter.swift Application/Project/ProjectModels.swift Application/Project/MIDIItem.swift Application/Project/ItemFade.swift Application/Project/ItemFadeCurve.swift Application/Project/TimelineTempo.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
