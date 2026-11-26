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
extension View { func interfaceScaled() -> some View { self } }
final class InterfaceScaling { static let shared = InterfaceScaling(); func register(_ window: NSWindow) {} }
extension NSFont { static func jarasBoldSystemFont(ofSize size: CGFloat) -> NSFont { .boldSystemFont(ofSize: size) } }
enum JarasLocalization { static func string(_ value: String) -> String { value } }
struct TPNoticeEditor: View { let model: TPNoticeController; var body: some View { EmptyView() } }
'''
overlay=source[source.index('private struct TPNoticeOverlay: View'):source.index('\n#endif', source.index('private struct TPNoticeOverlay: View'))]
overlay=overlay.replace('context.date.timeIntervalSince(model.sentAt)', '0.0')
helpers='''extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 255)/255, green: Double((hex >> 8) & 255)/255, blue: Double(hex & 255)/255) }
}
'''
layout = source[:source.index('#if os(macOS)\nimport AppKit\nimport Combine')]
layout = layout.replace('NSFont.jarasBoldSystemFont', 'NSFont.boldSystemFont')
colors = Path('Application/Project/ProjectModels.swift').read_text().split('public enum ItemTextColors {',1)[1]
colors = 'public enum ItemTextColors {' + colors.split('/// Presentation only:',1)[0]
views = 'extension ItemTextColors {' + Path('Apple/Shared/TextItemEditor.swift').read_text().split('extension ItemTextColors {',1)[1]
remote = Path('Apple/Shared/DAWRemoteView.swift').read_text()
remote = remote[remote.index('private struct RemoteNativeNoticeOverlay: View'):remote.index('@MainActor struct RemoteNativeNoticesView: View')]
remoteStubs = '''
final class DAWRemoteSession { static let shared = DAWRemoteSession() }
struct RemoteNativeProjectionImage: View { let id: UUID; let project: UUID; let remote: DAWRemoteSession; var body: some View { Color.purple } }
func remoteColor(_ value: UInt32) -> Color { Color(hex: value) }
'''
Path(sys.argv[1]).write_text(stubs+layout+code+overlay+"\n"+helpers+colors+views+remoteStubs+remote+Path('Tests/Apple/TeleprompterNoticeTests.swift').read_text()+Path('Tests/Apple/TeleprompterNoticeProjectionTests.swift').read_text())
PY
swiftc -swift-version 5 Application/Project/TeleprompterSettings.swift Apple/Shared/DAWRemoteProtocol.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
