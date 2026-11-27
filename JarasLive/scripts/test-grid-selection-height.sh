#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-selection-height.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/GridSelectionInput.swift').read_text()
start = source.index('struct GridSelectionItem {')
typography = '// App-owned typography.' + Path('Apple/Shared/Theme.swift').read_text().split('// App-owned typography.', 1)[1]
metrics = '\nimport AppKit\nimport CoreText\n'+typography+'\n'+source[source.index('enum GridSelectionHeaderText {'):source.index('enum GridSelectionHeaderControls {')]
appearance = source.index('enum TrackMixerButtonAppearance {')
metrics += '\n' + source[appearance:source.index('\n}', appearance) + 2] + '\n'
models = Path('Application/Project/ProjectModels.swift').read_text()
elastic = models[models.index('public struct ElasticPoint:'):models.index('public struct AudioClip:')]
theme = Path('Apple/Shared/Theme.swift').read_text()
metrics += '\nextension Color {' + theme.split('extension Color {', 1)[1].split('\n}', 1)[0] + '\n}\n'
selection = elastic + source[source.index('struct ElasticOverlayGeometry {'):source.index('#if os(macOS)\nimport AppKit', start)]
grid = Path('Apple/Shared/TimelineGridView.swift').read_text()
start = grid.index('@MainActor private final class TimelineSelectionLayoutCache {')
cache = grid[start:grid.index('@MainActor private final class TrackLayoutCache', start)]
start = grid.index('private struct TimelineContentKey:')
cache = grid[start:grid.index('\n}', start) + 2].replace('revision: UInt64', 'revision: Int') + '\n' + cache
prefix = 'import AppKit\nimport SwiftUI\nstruct TimelineRenderKey: Equatable { let revision: Int; var songID: UUID? = nil; var projectID: UUID? = nil; var hiddenTracks: Set<UUID> = [] }\n'
Path(sys.argv[1]).write_text(prefix + selection + metrics + cache + '\n' + Path('Tests/Apple/GridSelectionHeightTests.swift').read_text())
PY
swiftc Application/Project/ItemFadeCurve.swift -O -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
