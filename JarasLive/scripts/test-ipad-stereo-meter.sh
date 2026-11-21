#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-ipad-meter.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
audio = Path('Apple/Shared/StemAudioPlayback.swift').read_text()
style = audio[audio.index('enum MixerMeterStyle {'):audio.index('struct MixerFaderMeter:')]
theme = Path('Apple/Shared/Theme.swift').read_text()
display = '; '.join(line.strip() for line in theme.splitlines() if 'static let displayHex:' in line or 'static let lightDarkBackgroundHex:' in line)
interface = theme[theme.index('enum JarasInterfaceTheme:'):theme.index('enum JarasTheme {')]
color = theme[theme.index('extension Color {'):theme.index('#if os(macOS)\nenum DesktopToolbarTone')]
Path(sys.argv[1]).write_text('import SwiftUI\nimport QuartzCore\nenum JarasTheme { ' + display + ' }\n' + interface + color + style + '\n' + Path('Tests/Apple/IpadStereoMeterTests.swift').read_text())
PY
swiftc -O -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
