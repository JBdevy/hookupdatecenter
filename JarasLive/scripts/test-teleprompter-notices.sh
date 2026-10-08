#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-notices.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source=Path('Apple/Shared/TeleprompterWindow.swift').read_text()
code=source[source.index('struct TPNoticeAppearance: Codable'):source.index('struct TPNoticeButton: View')]
stubs='''import SwiftUI
import AppKit
import UniformTypeIdentifiers
enum JarasLocalization { static func string(_ value: String) -> String { value } }
struct TPNoticeEditor: View { let model: TPNoticeController; var body: some View { EmptyView() } }
'''
overlay=source[source.index('private struct TPNoticeOverlay: View'):source.rindex('#endif')]
overlay=overlay.replace('context.date.timeIntervalSince(model.sentAt)', '0.0')
helpers='''extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 255)/255, green: Double((hex >> 8) & 255)/255, blue: Double(hex & 255)/255) }
}
'''
fonts=source[source.index('private func tpFont('):source.index('#if os(macOS)\nimport AppKit\nimport Combine')]
Path(sys.argv[1]).write_text(stubs+code+overlay+helpers+fonts+Path('Tests/Apple/TeleprompterNoticeTests.swift').read_text())
PY
swiftc -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
