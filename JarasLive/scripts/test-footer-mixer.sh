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
a = s.index('@MainActor final class TrackMIDIActivity'); b = s.index('@MainActor final class TrackMeterLevel')
(out / 'midi.swift').write_text('import SwiftUI\n' + s[a:b] + Path('Tests/Apple/MIDIKeyboardTests.swift').read_text())
s = Path('Apple/Shared/TrackMixerRow.swift').read_text()
posted = sys.argv[2] == '--posted-wheel'
a = s.index('private struct FooterMixerScroll:') if posted else s.index('private final class FooterMixerGreenScroller:')
b = s.index('\n#endif', a)
layout = s[s.index('private struct FooterMixerStripLayout {'):s.index('private struct FooterMixerRenderState:')]
body = (layout + s[a:b]).replace('private func smoothWheel(', 'fileprivate func smoothWheel(')
body = body.replace('private func routeWheel(', 'fileprivate func routeWheel(')
body = body.replace('private var cachedStrips:', 'fileprivate var cachedStrips:')
body = body.replace('private var pendingStripLayout:', 'fileprivate var pendingStripLayout:')
body = body.replace('strips[index]?.layoutSubtreeIfNeeded()', 'strips[index]?.layoutSubtreeIfNeeded(); FooterScrollLayoutProbe.forced += 1')
body = body.replace('guard !preparing, let makeContent else { return }',
                    'FooterScrollLayoutProbe.preparations += 1; guard !preparing, let makeContent else { return }')
if posted:
    body = body.replace('view.setSlotsOnly = { UserDefaults.standard.set($0, forKey: \"catlive.hozMixer.slotsOnly\") }', 'view.setSlotsOnly = setPostedMode')
body = 'enum FooterScrollLayoutProbe { static var forced = 0; static var preparations = 0 }\n' + body
meter = Path('Apple/Shared/StemAudioPlayback.swift').read_text()
model = meter[meter.index('@MainActor final class TrackMeterLevel'):meter.index('/// Item edges')]
native = meter[meter.index('/// Uses the existing stereo readings'):meter.index('private final class PreparedSoundFont')]
# The isolated meter/scroll fixture exercises geometry and levels, not bundled font registration.
native = native.replace('NSFont.jarasMonospacedSystemFont', 'NSFont.monospacedSystemFont')
(out / 'scroll.swift').write_text('import SwiftUI\nimport AppKit\nimport Combine\n' + model + '\n' + native + '\n' + body + '\n' + Path('Tests/Apple/' + ('FooterMixerPostedWheelTests.swift' if posted else 'FooterMixerScrollTests.swift')).read_text())
PYTHON
swiftc -parse-as-library "$build_dir/midi.swift" -o "$build_dir/midi"
"$build_dir/midi"
swiftc "$build_dir/scroll.swift" -o "$build_dir/scroll"
"$build_dir/scroll"
