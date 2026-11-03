#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
zoom_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-zoom-grid-anchor.XXXXXX")"
trap 'rm -rf "$zoom_test_dir"' EXIT
python3 - "$zoom_test_dir/main.swift" "${1:-current}" <<'PYTHON'
from pathlib import Path
import sys
source = Path('Apple/Shared/TimelineGridView.swift').read_text()
if sys.argv[2] == 'legacy':
    source = source.replace('let x = position - tile.minX + pixel / 2',
        'let x = floor(position * scale) / scale + pixel / 2 - tile.minX')
    source = source.replace('let x = tick.x - value.viewport.minX + pixel / 2',
        'let x = floor(tick.x * scale) / scale + pixel / 2 - value.viewport.minX')
fonts = Path('Apple/Shared/Theme.swift').read_text()
fonts = fonts[fonts.index('private enum CatLiveTypeface {'):fonts.index('\n#endif', fonts.index('private enum CatLiveTypeface {'))]
Path(sys.argv[1]).with_name('Fonts.swift').write_text('import SwiftUI\nimport AppKit\nimport CoreText\n' + fonts)
parts = ['import AppKit\nimport SwiftUI\n']
for begin in ['private struct TimelineNativeGridBand {', 'private struct TimelineNativeRuler:']:
    start = source.index(begin)
    parts.append(source[start:source.index('\n#endif', start)])
parts.append(Path('Tests/Apple/TimelineZoomGridAnchorTests.swift').read_text())
Path(sys.argv[1]).write_text('\n'.join(parts))
PYTHON
swiftc -swift-version 5 "$zoom_test_dir/Fonts.swift" Apple/Shared/TimelineStaticText.swift "$zoom_test_dir/main.swift" -o "$zoom_test_dir/test"
"$zoom_test_dir/test" "${1:-current}"
