#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-footer.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
python3 - "$build_dir" <<'PYTHON'
from pathlib import Path
import sys
out = Path(sys.argv[1])
s = Path('Apple/Shared/StemAudioPlayback.swift').read_text()
a = s.index('@MainActor final class TrackMIDIActivity'); b = s.index('@MainActor final class TrackMeterLevel')
(out / 'midi.swift').write_text('import SwiftUI\n' + s[a:b] + Path('Tests/Apple/MIDIKeyboardTests.swift').read_text())
s = Path('Apple/Shared/TrackMixerRow.swift').read_text()
a = s.index('private final class FooterMixerGreenScroller:'); b = s.index('\n#endif', a)
body = s[a:b].replace('private func smoothWheel(', 'fileprivate func smoothWheel(')
(out / 'scroll.swift').write_text('import SwiftUI\nimport AppKit\n' + body + '\n' + Path('Tests/Apple/FooterMixerScrollTests.swift').read_text())
PYTHON
swiftc -parse-as-library "$build_dir/midi.swift" -o "$build_dir/midi"
"$build_dir/midi"
swiftc "$build_dir/scroll.swift" -o "$build_dir/scroll"
"$build_dir/scroll"
