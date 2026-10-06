#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-native-notice.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PYTEST'
from pathlib import Path
import sys
source = Path('Apple/Shared/TransportView.swift').read_text()
start = source.index('private final class NativeTransportInformationView:')
source = source[start:source.index('\n#endif', start)].replace('private final class', 'final class')
source = source.replace('    override func layout()', '    var layoutCount = 0\n    override func layout()').replace('super.layout(); updateGeometry()', 'layoutCount += 1; super.layout(); updateGeometry()')
theme = Path('Apple/Shared/Theme.swift').read_text()
theme = theme[:theme.index('    static func track(')] + '}\n' + theme[theme.index('extension Color {'):]
Path(sys.argv[1]).write_text('import SwiftUI\nimport AppKit\n' + theme + '\n' + source + '\n' + Path('Tests/Apple/NativeTransportInformationTests.swift').read_text())
PYTEST
swiftc -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
