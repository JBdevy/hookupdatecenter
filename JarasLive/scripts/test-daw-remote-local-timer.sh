#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-remote-local-timer.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/DAWRemoteView.swift').read_text()
source = source[source.index('// MARK: - Local Remote timer\n'):]
tests = Path('Tests/Apple/DAWRemoteLocalTimerTests.swift').read_text()
theme = '''enum JarasTheme {
    static let green = Color.green, secondary = Color.gray, display = Color.black
    static let panel = Color.gray, text = Color.white, line = Color.gray
}\n'''
Path(sys.argv[1]).write_text('import SwiftUI\nimport AppKit\n' + theme + source + '\n@MainActor func runTests() {\n' + tests + '\n}\nTask { @MainActor in runTests(); exit(0) }\nRunLoop.main.run()\n')
PY
swiftc -swift-version 5 Application/Project/TeleprompterSettings.swift Apple/Shared/DAWRemoteProtocol.swift Application/Project/TeleprompterTimer.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
