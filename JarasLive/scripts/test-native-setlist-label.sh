#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-native-setlist.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import re,sys
source=Path('Apple/Shared/SongListView.swift').read_text()
start=source.index('private struct SetlistPlaybackBinding:')
end=source.index('struct SongListPreview',start)
code=source[start:end]
code=code.replace('private final class NativeRegionSetlistLabelView: NSView {', 'private final class NativeRegionSetlistLabelView: NSView {\n    var drawingCount = 0')
code=code.replace('    override func draw(_ dirtyRect: NSRect) {', '    override func draw(_ dirtyRect: NSRect) {\n        drawingCount += 1')
row=code[code.index('private struct RegionSetlistRow:'):code.index('#if os(macOS)\nimport AppKit')]
# The retained iPad label is also the visual baseline for native macOS drawing.
original=re.sub(r'#if os\(macOS\).*?#else\n(.*?)#endif',r'\1',row,flags=re.S).replace('RegionSetlistRow','OriginalRegionSetlistRow')
theme=Path('Apple/Shared/Theme.swift').read_text()
colors=theme[:theme.index('    static func track(')]+'}\n'+theme[theme.index('extension Color {'):theme.index('struct StageButtonStyle')]
Path(sys.argv[1]).write_text(colors+'\n'+code+'\n'+original+'\n'+Path('Tests/Apple/NativeSetlistLabelTests.swift').read_text())
PY
swiftc -suppress-warnings -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
