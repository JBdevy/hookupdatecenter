#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-notice-feedback.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
out = Path(sys.argv[1])
source = Path('Apple/Shared/DAWRemoteView.swift').read_text()
shared = source[source.index('// MARK: - Remote notice presentation'):source.index('// MARK: - Local Remote timer')]
protocol = Path('Apple/Shared/DAWRemoteProtocol.swift').read_text()
stubs = '''import SwiftUI
enum JarasTheme { static let green = Color.green, yellow = Color.yellow, panel = Color.gray, text = Color.white, secondary = Color.gray }
enum JarasLocalization { static func string(_ key: String) -> String { key } }
'''
window = Path('Apple/Shared/TeleprompterWindow.swift').read_text()
controller = window[window.index('struct TPNoticeAppearance: Codable'):window.index('struct TPNoticeButton: View')]
editor = window[window.index('private struct TPNoticeEditor: View'):window.index('struct TPNoticeSettingsView: View')]
out.joinpath('main.swift').write_text('import AppKit\nimport UniformTypeIdentifiers\n' + stubs + shared + controller + editor + Path('Tests/Apple/NoticeSendFeedbackTests.swift').read_text())
notices = source[source.index('@MainActor struct RemoteNativeNoticesView: View'):source.index('\n#endif', source.index('@MainActor struct RemoteNativeNoticesView: View'))]
out.joinpath('iOS.swift').write_text('import UIKit\n' + stubs + 'enum RemoteSurface { static let panel = Color.gray, display = Color.black }\n' + shared + notices)
PY
swiftc -typecheck -swift-version 5 -target arm64-apple-ios16.0 -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" Application/Project/TeleprompterSettings.swift Apple/Shared/DAWRemoteProtocol.swift Apple/Shared/DAWRemoteSession.swift "$test_dir/iOS.swift"
swiftc -O -swift-version 5 Application/Project/TeleprompterSettings.swift Apple/Shared/DAWRemoteProtocol.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
