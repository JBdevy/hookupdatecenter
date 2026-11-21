#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-footer.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
python3 - "$build_dir" "${1:-}" <<'PYTHON'
from pathlib import Path
import sys
out = Path(sys.argv[1])
s = Path('Apple/Shared/StemAudioPlayback.swift').read_text()
a = s.index('@MainActor final class TrackMIDIActivity'); b = s.index('// Prepared sources own their PCM cursor.')
(out / 'midi.swift').write_text('import SwiftUI\n' + s[a:b] + Path('Tests/Apple/MIDIKeyboardTests.swift').read_text())
s = Path('Apple/Shared/TrackMixerRow.swift').read_text()
posted = sys.argv[2] == '--posted-wheel'
a = s.index('private struct FooterMixerScroll:') if posted else s.index('private final class FooterMixerDocumentView')
b = s.index('\n#endif', a)
layout = s[s.index('private struct FooterMixerStripLayout {'):s.index('private struct FooterMixerRenderState:')]
grid = Path('Apple/Shared/GridScrollView.swift').read_text()
scroller = grid[grid.index('    final class GreenScroller:'):grid.index('    private var timelineVerticalBar:')]
body = ('final class GridNativeScrollView {\n' + scroller + '}\n' + layout + s[a:b]).replace('private func smoothWheel(', 'fileprivate func smoothWheel(')
body = body.replace('private func routeWheel(', 'fileprivate func routeWheel(')
body = body.replace('private var cachedStrips:', 'fileprivate var cachedStrips:')
body = body.replace('private var pendingStripLayout:', 'fileprivate var pendingStripLayout:')
body = body.replace('func prepareChannelContent() -> Bool {', 'func prepareChannelContent() -> Bool { FooterScrollLayoutProbe.forced += 1')
body = body.replace('guard !preparing, let makeContent else { return }',
                    'FooterScrollLayoutProbe.preparations += 1; guard !preparing, let makeContent else { return }')
body = 'enum FooterScrollLayoutProbe { static var forced = 0; static var preparations = 0 }\n' + body
meter = Path('Apple/Shared/StemAudioPlayback.swift').read_text()
model = meter[meter.index('@MainActor final class TrackMeterLevel'):meter.index('/// Item edges')]
native = meter[meter.index('/// Uses the existing stereo readings'):meter.index('private final class PreparedSoundFont')]
theme = Path('Apple/Shared/Theme.swift').read_text()
display = '; '.join(line.strip() for line in theme.splitlines() if any(key in line for key in ('static let displayHex:', 'static let lightDarkBackgroundHex:', 'static let workspaceToolbar =', 'static let green =', 'static let liveOffRed =')))
interface = theme[theme.index('enum JarasInterfaceTheme:'):theme.index('enum JarasTheme {')]
# The isolated meter/scroll fixture exercises geometry and levels, not bundled font registration.
native = native.replace('NSFont.jarasMonospacedSystemFont', 'NSFont.monospacedSystemFont')
(out / 'scroll.swift').write_text('import SwiftUI\nimport AppKit\nimport Combine\nenum JarasTheme { ' + display + ' }\n' + 'extension Color { init(hex: UInt32) { self.init(red: Double((hex >> 16) & 255)/255, green: Double((hex >> 8) & 255)/255, blue: Double(hex & 255)/255) } }\n' + interface + '\n' + model + '\n' + native + '\n' + body + '\n' + Path('Tests/Apple/' + ('FooterMixerPostedWheelTests.swift' if posted else 'FooterMixerScrollTests.swift')).read_text())
PYTHON
swiftc -parse-as-library "$build_dir/midi.swift" -o "$build_dir/midi"
"$build_dir/midi"
cp "$build_dir/scroll.swift" "$build_dir/main.swift"
swiftc Apple/Shared/NativeTimelineInputGate.swift "$build_dir/main.swift" -o "$build_dir/scroll"
"$build_dir/scroll"
