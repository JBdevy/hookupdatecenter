#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
panel_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-missing-audio-panel.XXXXXX")"
trap 'rm -rf "$panel_test_dir"' EXIT
python3 - "$panel_test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source=Path('Apple/Shared/ProjectDocuments.swift').read_text()
panel=source[source.index('struct MissingAudioRecoveryPanel:'):source.index('struct ProjectBrowserView:')]
for role in ['header','details','actions']:
    marker=f'.accessibilityIdentifier("missing-audio-{role}")'
    panel=panel.replace(marker, marker+f'.background(LayoutProbe(role: "{role}"))')
stubs='''import AppKit
import SwiftUI
enum JarasTheme { static let background = Color.black, panel = Color.gray, text = Color.white, secondary = Color.gray, yellow = Color.yellow, green = Color.green }
enum JarasLocalization { static func string(_ value: String) -> String { value } }
extension View { func jarasHelp(_ value: String) -> some View { help(value) } }
struct StageButtonStyle: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View { configuration.label.padding(6).background(color.opacity(0.3)) }
}
'''
Path(sys.argv[1]).write_text(stubs+panel+Path('Tests/Apple/MissingAudioPanelTests.swift').read_text())
PY
swiftc -swift-version 5 -target "$(uname -m)-apple-macos12.0" "$panel_test_dir/main.swift" -o "$panel_test_dir/test"
"$panel_test_dir/test"
