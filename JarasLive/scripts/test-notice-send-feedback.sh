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
extension Color { init(hex: UInt32) { self.init(red: Double((hex >> 16) & 255)/255, green: Double((hex >> 8) & 255)/255, blue: Double(hex & 255)/255) } }
extension Font { static func jarasSystem(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font { .system(size: size, weight: weight, design: design) }; static var jarasHeadline: Font { .headline }; static var jarasCaption: Font { .caption }; static var jarasCallout: Font { .callout } }
enum JarasTheme { static let green = Color.green, yellow = Color.yellow, panel = Color.gray, text = Color.white, secondary = Color.gray }
enum JarasLocalization { static func string(_ key: String) -> String { key } }
'''
window = Path('Apple/Shared/TeleprompterWindow.swift').read_text()
controller = window[window.index('struct TPNoticeAppearance: Codable'):window.index('struct TPNoticeButton: View')]
editor = window[window.index('private struct NoticeEditorBackground:'):window.index('private struct TPNoticeOverlay: View')]
out.joinpath('main.swift').write_text('import AppKit\nimport UniformTypeIdentifiers\nextension View { func interfaceScaled() -> some View { self } }\nfinal class InterfaceScaling { static let shared = InterfaceScaling(); func register(_ window: NSWindow) {} }\n' + stubs + shared + controller + editor + Path('Tests/Apple/NoticeSendFeedbackTests.swift').read_text())
notices = source[source.index('@MainActor struct RemoteNativeNoticesView: View'):source.index('\n#endif', source.index('@MainActor struct RemoteNativeNoticesView: View'))]
native = Path('Apple/Shared/IpadStandaloneWorkspace.swift').read_text()
native = native[native.index('struct TPNoticeAppearance: Codable'):native.index('\n#endif', native.index('struct TPNoticeAppearance: Codable'))]
out.joinpath('iOS.swift').write_text('import UIKit\n' + native + '\n' + stubs + 'enum RemoteSurface { static let panel = Color.gray, display = Color.black }\n' + shared + notices)
PY
swiftc -typecheck -swift-version 5 -target arm64-apple-ios16.0 -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" Application/Project/TeleprompterSettings.swift Apple/Shared/DAWRemoteProtocol.swift Apple/Shared/DAWRemoteSession.swift "$test_dir/iOS.swift"
swiftc -O -swift-version 5 Application/Project/TeleprompterSettings.swift Apple/Shared/DAWRemoteProtocol.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
