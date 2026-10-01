#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-window-chrome.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PYTHON'
from pathlib import Path
import sys
source = Path('Apple/Shared/ProjectDocuments.swift').read_text()
start = source.index('/// Keep project controls in AppKit')
end = source.index('\n#endif', start)
stubs = '''import AppKit
import SwiftUI
enum JarasTheme {
    static let titlebar = Color(red: 39.0 / 255, green: 46.0 / 255, blue: 56.0 / 255)
}
final class ProjectDocuments { var folderReview: Bool? }
final class ProjectCloseGuard {
    static let shared = ProjectCloseGuard()
    func attach(window: NSWindow, documents: ProjectDocuments) {}
}
'''
Path(sys.argv[1]).write_text(stubs + source[start:end] + '\n' + Path('Tests/Apple/ProjectWindowChromeTests.swift').read_text())
PYTHON
swiftc -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
