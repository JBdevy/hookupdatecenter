#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-native-ruler.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
fonts = Path('Apple/Shared/Theme.swift').read_text()
start = fonts.index('enum CatLiveTypeface {')
fonts = fonts[start:fonts.index('/// Keep custom AppKit drawing', start)] + '#endif\n'
start = fonts.index('    static func font(_ style:')
end = fonts.index('\n}', start)
fonts = fonts[:start] + fonts[end:]
Path(sys.argv[1]).with_name('Fonts.swift').write_text('import SwiftUI\nimport AppKit\nimport CoreText\n' + fonts)
source = Path('Apple/Shared/TimelineGridView.swift').read_text()
start = source.index('private struct TimelineNativeRuler:')
end = source.index('\n#endif', start)
Path(sys.argv[1]).write_text('import AppKit\nimport SwiftUI\n' + source[start:end] + '\n' + Path('Tests/Apple/NativeTimelineRulerTests.swift').read_text())
PY
swiftc -swift-version 5 "$test_dir/Fonts.swift" Apple/Shared/TimelineGridInk.swift Apple/Shared/TimelineStaticText.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
