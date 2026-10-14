#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-presentation-session.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" "${CATLIVE_SETLIST_SESSION_TEST_SOURCE:-Apple/Shared/SongListView.swift}" "${CATLIVE_VIDEO_SESSION_TEST_SOURCE:-Apple/Shared/VideoPlayback.swift}" <<'PY'
from pathlib import Path
import sys
fixture = Path('Tests/Apple/ProjectPresentationSessionTests.swift').read_text()
setlist = Path(sys.argv[2]).read_text()
start = setlist.index('    func performDrop(info: DropInfo) -> Bool {', setlist.index('private struct SetlistInsertionDrop:'))
end = setlist.index('\n}\nprivate struct LockedRegionDrag:', start)
drop = setlist[start:end]
drop = drop.replace('            Task { @MainActor in\n', '            Task { @MainActor in\n                defer { show.completedDrops += 1 }\n')
video = Path(sys.argv[3]).read_text()
start = video.index('    private func reset() {')
reset = video[start:video.index('\n    func update(', start)]
start = video.index('    func open(directory: URL) {')
opened = video[start:video.index('\n    func closeProject()', start)]
start = video.index('            let requestedGeneration = generation', video.index('        if changedClip {'))
end = video.index('\n            player.replaceCurrentItem', start)
status = video[start:end]
status = status.replace('            itemStatus = item.observe(\\.status, options: [.new]) { [weak self] item,_ in\n                let error = item.error?.localizedDescription\n', '')
status = status.rsplit('\n            }', 1)[0]
status = status.replace('                Task { @MainActor [weak self] in', '                return Task { @MainActor [weak self] in')
Path(sys.argv[1]).write_text(fixture.replace('    // INSERT_DROP', drop).replace('    // INSERT_VIDEO_RESET', reset).replace('    // INSERT_VIDEO_OPEN', opened).replace('        // INSERT_VIDEO_STATUS', status))
PY
swiftc -swift-version 5 Apple/Shared/AudioExportSelection.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
