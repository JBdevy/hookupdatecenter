#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-footer-resize.XXXXXX")"
footer_ax_pid=""
cleanup() {
    if [[ -n "$footer_ax_pid" ]]; then kill "$footer_ax_pid" 2>/dev/null || true; fi
    rm -rf "$test_dir"
}
trap cleanup EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/MainView.swift').read_text()
start = source.index('enum FooterHeightRole')
subject = source[start:source.index('\n#else\nfinal class FooterVerticalResizeCoordinator', start)]
transport = Path('Apple/Shared/TransportView.swift').read_text()
start = transport.index('struct FooterPlaylistDisplay:')
playlist = transport[start:transport.index('\n#endif', start)]
start = transport.index('struct SongNameDisplay:')
display = transport[start:transport.index('private struct PanelCollapseButton:', start)]
# Count the font actually requested by the production view, without adding a
# test counter or extra observation to the application.
display = display.replace('private var fontScale: CGFloat { max(1, sqrt(height / 25)) }',
    'private var fontScale: CGFloat { let value = max(1, sqrt(height / 25)); FooterJournal.fontScales.append(value); return value }')
theme = Path('Apple/Shared/Theme.swift').read_text()
colors = theme[theme.index('enum JarasTheme {'):theme.index('    static func track(')] + '}\n'
colors += theme[theme.index('extension Color {'):theme.index('struct StageButtonStyle:')]
fx = Path('Apple/Shared/FXEditor.swift').read_text()
keys = fx[fx.index('private struct OpenFXKey:'):fx.index('enum FXModelLookup')]
region = Path('Apple/Shared/RegionEditor.swift').read_text()
keys += region[region.index('/// Immutable menu target:'):]
fixture = Path('Tests/Apple/NativeFooterHeightTests.swift').read_text()
direct = Path('Tests/Apple/FooterDisplayResizeTests.swift').read_text().replace('// INSERT_FOOTER_RESIZE_VIEW', '')
accessibility = Path('Tests/Apple/NativeFooterAccessibilityTests.swift').read_text()
Path(sys.argv[1]).write_text(fixture.replace('// INSERT_FOOTER_RESIZE_VIEW', keys + '\n' + subject + '\n' + colors + playlist + '\n' + display) + '\n' + direct + '\n' + accessibility)
PY
swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos12.0" \
    Apple/Shared/NativeTimelineInputGate.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
swiftc -swift-version 5 Tests/Apple/NativeFooterAccessibilityDriver.swift -o "$test_dir/ax"
"$test_dir/test" --accessibility >"$test_dir/ax.log" 2>&1 &
footer_ax_pid=$!
if "$test_dir/ax" "$footer_ax_pid"; then
    if ! wait "$footer_ax_pid"; then cat "$test_dir/ax.log"; exit 1; fi
    cat "$test_dir/ax.log"
else
    result=$?
    if [[ "$result" != 77 ]]; then cat "$test_dir/ax.log"; exit "$result"; fi
    kill "$footer_ax_pid" 2>/dev/null || true
    wait "$footer_ax_pid" 2>/dev/null || true
fi
footer_ax_pid=""
