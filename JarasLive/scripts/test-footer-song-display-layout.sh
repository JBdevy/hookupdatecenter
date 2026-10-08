#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -e /tmp/catlive-perf-measurement.lock ]]; then
    echo "Performance measurement is active; footer layout fixture deferred." >&2
    exit 2
fi
footer_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-footer-song-layout.XXXXXX")"
trap 'rm -rf "$footer_test_dir"' EXIT
python3 - "$footer_test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/TransportView.swift').read_text()
subject = source[source.index('struct SongNameDisplay:'):source.index('private struct PanelCollapseButton:')]
colors = Path('Apple/Shared/Theme.swift').read_text()
colors = colors[colors.index('enum JarasTheme {'):colors.index('    static func track(')] + '}\n' + colors[colors.index('extension Color {'):colors.index('struct StageButtonStyle:')]
fixture = Path('Tests/Apple/FooterSongDisplayLayoutTests.swift').read_text()
Path(sys.argv[1]).write_text(fixture.replace('// INSERT_FOOTER_SONG_DISPLAYS', colors + '\n' + subject))
PY
swiftc -swift-version 5 -target "$(uname -m)-apple-macos12.0" "$footer_test_dir/main.swift" -o "$footer_test_dir/test"
"$footer_test_dir/test"
