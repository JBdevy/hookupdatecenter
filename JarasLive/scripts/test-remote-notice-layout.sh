#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-notice-layout.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/DAWRemoteView.swift').read_text()
shared = source[source.index('// MARK: - Remote notice presentation'):source.index('// MARK: - Local Remote timer')]
stubs = '''import SwiftUI
enum JarasTheme { static let green = Color.green, yellow = Color.yellow, panel = Color.gray, text = Color.white, secondary = Color.gray }
enum JarasLocalization { static func string(_ key: String) -> String { key } }
'''
Path(sys.argv[1], 'main.swift').write_text('import AppKit\n' + stubs + shared + Path('Tests/Apple/RemoteNoticeLayoutTests.swift').read_text())
PY
swiftc -O -swift-version 5 Application/Project/TeleprompterSettings.swift Apple/Shared/DAWRemoteProtocol.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
