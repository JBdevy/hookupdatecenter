#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-advanced-playback.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swift build --product JarasApplication >/dev/null
products="$(swift build --show-bin-path)"
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
folder = Path(sys.argv[1])
source = Path('Apple/Shared/AdvancedView.swift').read_text()
root = source[source.index('struct AdvancedView:'):source.index('\nstruct TempoMarkerEditor:')]
timeline = source[source.index('private struct AdvancedTimelineSettings:'):source.index('\nprivate struct AdvancedSetlistColors:')]
root = root.replace('    var body: some View {', '''    var body: some View {
        let _ = { AdvancedPresentationProbe.root += 1; AdvancedPresentationProbe.draft = bpm
            AdvancedPresentationProbe.observedColor = show.snapshot.project.masterColor
            AdvancedPresentationProbe.editDraft = { bpm = $0 }
            AdvancedPresentationProbe.selectTimeline = { tab = .timeline } }()
''', 1)
timeline = timeline.replace('    var body: some View {', '    var body: some View {\n        let _ = { AdvancedPresentationProbe.timeline += 1 }()', 1)
fixture = Path('Tests/Apple/AdvancedPlaybackPresentationTests.swift').read_text()
views = root + '\n' + timeline
(folder/'main.swift').write_text(fixture.replace('// INSERT_PRODUCTION_VIEWS', views))
# A before/after control restores only the former direct model subscription.
# All controls, production observers, edits and test actions remain identical.
old = views.replace('    let show: ShowController\n', '    @ObservedObject var show: ShowController\n')
(folder/'baseline').mkdir()
(folder/'baseline/main.swift').write_text(fixture.replace('// INSERT_PRODUCTION_VIEWS', old))
PY
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos12.0" -I "$products" -L "$products" -lJarasApplication "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos12.0" -I "$products" -L "$products" -lJarasApplication "$test_dir/baseline/main.swift" -o "$test_dir/baseline/test"
"$test_dir/baseline/test" --baseline
