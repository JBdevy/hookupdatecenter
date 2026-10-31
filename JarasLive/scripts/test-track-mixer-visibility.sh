#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-mixer-visibility.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" "${1:-}" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/TrackMixerRow.swift').read_text()
geometry = source[source.index('struct TrackMixerHeightGeometry {'):source.index('private struct LegacyMixerHeightKey:')]
start = source.index('private final class TrackMixerNativeContent {')
end = source.index('\n#endif', start)
fixture = Path('Tests/Apple/TrackMixerVisibilityTests.swift').read_text()
subject = geometry + source[start:end]
subject = subject.replace('private final class TrackMixerControlHost: NSHostingView<AnyView> {',
    'private final class TrackMixerControlHost: NSHostingView<AnyView> {\n    override func viewDidMoveToWindow() { VisibilityJournal.windowTransitions += 1; super.viewDidMoveToWindow() }')
# Negative control retains production code except the former immediate detach.
if "--legacy" in sys.argv:
    subject = subject.replace('if visibilityObserver?.defersHostDetachment != true { setHostsAttached(false) }', 'setHostsAttached(false)')
Path(sys.argv[1]).write_text(fixture.replace('// INSERT_NATIVE_TRACK_MIXER_VISIBILITY', subject))
PY
swiftc -swift-version 5 Apple/Shared/NativeTimelineInputGate.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test" "${1:-}"
