#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-tp-layout.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
layout = Path('Apple/Shared/TeleprompterWindow.swift').read_text()
layout = layout[:layout.index('#if os(macOS)\nimport AppKit\nimport Combine')]
# Freeze the display clock, so a changed second or RGB hue cannot pass a test
# whose actual configuration has no effect. Keep the real presentation code.
start = layout.index('TimelineView(.periodic(')
end = layout.index('\n', start)
layout = layout[:start] + 'Group {' + layout[end:]
layout = layout.replace('context.date', 'Date(timeIntervalSince1970: 1000)')
protocol = Path('Apple/Shared/DAWRemoteProtocol.swift').read_text()
protocol = protocol[protocol.index('struct DAWRemoteTeleprompter:'):protocol.index('struct DAWRemoteNotices:')]
config = Path('Apple/Shared/TeleprompterConfig.swift').read_text()
config = config[config.index('@MainActor final class TeleprompterPreferences:'):config.index('struct TeleprompterConfig: View')]
helpers = '''extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 255)/255, green: Double((hex >> 8) & 255)/255, blue: Double(hex & 255)/255) }
}
'''
Path(sys.argv[1]).write_text(layout + protocol + config + helpers + Path('Tests/Apple/TeleprompterLayoutTests.swift').read_text())
PY
swiftc -swift-version 5 Application/Project/TeleprompterSettings.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
