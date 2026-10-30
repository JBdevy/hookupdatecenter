#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-track-drop.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/TrackMixerRow.swift').read_text()
start = source.index('private final class TrackReorderState:')
state = source[start:source.index('\nprivate struct TrackInsertionDrop:', start)].replace('private final class TrackReorderState:', 'final class TrackReorderState:')
stubs = 'import SwiftUI\nimport UniformTypeIdentifiers\nfinal class TrackDragSource {}\nenum JarasTheme { static let yellow = Color.yellow; static let green = Color.green }\n'
delegate = source[source.index('private struct TrackInsertionDrop:'):source.index('/// Keep a visible rejection badge')]
commit = delegate[delegate.index('    func performDrop(info: DropInfo)'):delegate.rindex('\n}')]
geometry = delegate[delegate.index('    private func after('):delegate.index('    private func indicate(')]
fixture = Path('Tests/Apple/TrackDropCommitTests.swift').read_text()
fixture = fixture.replace('// PRODUCTION_DROP_METHODS', geometry + commit)
Path(sys.argv[1]).write_text(stubs + state + '\n' + fixture + '\n' + Path('Tests/Apple/TrackDropIndicatorTests.swift').read_text())
PY
swiftc -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
