#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-control-cursor.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
folder = Path(sys.argv[1])
source = Path('Apple/Shared/TrackMixerRow.swift').read_text()
start = source.index('final class TrackControlSelectionExclusionView:')
view = source[start:source.index('@MainActor final class TrackSelectionRouter', start)]
view = view.replace('final class TrackControlSelectionExclusionView:', 'class TrackControlSelectionExclusionView:', 1)
view = view.replace('        defaultCursorHost = nil\n        var ancestor = superview',
                    '        defaultCursorHost = nil\n        CursorProbeCounts.discoveries += 1\n        var ancestor = superview', 1)
gate = Path('Apple/Shared/NativeTimelineInputGate.swift').read_text()
gate = 'import AppKit\nprotocol NativeTimelineDefaultCursorHost: AnyObject {}\n' + gate[
    gate.index('protocol NativeTimelineInputObserver:'):gate.index('struct NativeTimelineModalGate:')]
(folder/'gate.swift').write_text(gate)
fixture = Path('Tests/Apple/TrackControlCursorCoverageTests.swift').read_text()
(folder/'main.swift').write_text(fixture.replace('// INSERT_PRODUCTION_CURSOR_VIEW', view))
old = view.replace('''        if let host = defaultCursorHost, host.window === window, isDescendant(of: host),
           host.bounds.intersection(host.visibleRect).contains(host.convert(rect, from: self)) { return }
''', '')
old = old.replace('        defaultCursorHost = nil\n', '').replace('                defaultCursorHost = view\n', '')
assert old != view
(folder/'baseline').mkdir()
(folder/'baseline/main.swift').write_text(fixture.replace('// INSERT_PRODUCTION_CURSOR_VIEW', old))
PY
for variant in fixed baseline; do
    if [[ "$variant" = fixed ]]; then source="$test_dir/main.swift"; else source="$test_dir/baseline/main.swift"; fi
    swiftc -O -swift-version 5 -target "${CATLIVE_TEST_ARCH:-$(uname -m)}-apple-macos12.0" "$test_dir/gate.swift" "$source" -o "$test_dir/$variant-test"
    if [[ -n "${CATLIVE_TEST_EXPORT_DIRECTORY:-}" ]]; then
        mkdir -p "$CATLIVE_TEST_EXPORT_DIRECTORY"
        cp "$test_dir/$variant-test" "$CATLIVE_TEST_EXPORT_DIRECTORY/$variant-test"
    elif [[ "$variant" = fixed ]]; then "$test_dir/$variant-test"; else "$test_dir/$variant-test" --baseline; fi
done
