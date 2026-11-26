#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-mixer-visibility.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" "${1:-}" <<'PY'
from pathlib import Path
import sys
sys.path.insert(0, 'scripts')
from native_mixer_test_sources import native_mixer_sources
fixture = Path('Tests/Apple/TrackMixerVisibilityTests.swift').read_text()
subject = '\n'.join(native_mixer_sources())
subject = subject.replace('private final class TrackMixerControlPlane: NSView {',
    'private final class TrackMixerControlPlane: NSView {\n    override func viewDidMoveToWindow() { VisibilityJournal.windowTransitions += 1; super.viewDidMoveToWindow() }')
# Negative control retains production code except the former immediate detach.
if "--legacy" in sys.argv:
    subject = subject.replace('if visibilityObserver?.defersHostDetachment != true { setHostsAttached(false) }', 'setHostsAttached(false)')
if "--legacy-height" in sys.argv:
    start = subject.index('        if let document = clip.documentView {')
    end = subject.index('        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification', start)
    subject = subject[:start] + subject[start:end].replace('self?.deferDetachmentUntilScrollSettles()', '') + subject[end:]
Path(sys.argv[1]).write_text(fixture.replace('// INSERT_NATIVE_TRACK_MIXER_VISIBILITY', subject))
PY
swiftc -swift-version 5 Apple/Shared/JarasLegacyLayout.swift Apple/Shared/NativeTimelineInputGate.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test" "${1:-}"
