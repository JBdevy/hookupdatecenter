#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-grid-hosting.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/environment.swift" <<'PY'
from pathlib import Path
import sys
fx = Path('Apple/Shared/FXEditor.swift').read_text()
text = Path('Apple/Shared/TextItemEditor.swift').read_text()
region = Path('Apple/Shared/RegionEditor.swift').read_text()
track_environment = region[region.index('/// Immutable menu target:'):]
Path(sys.argv[1]).write_text(fx[:fx.index('enum FXModelLookup')] + text[:text.index('/// The draft')] + track_environment)
PY
python3 - "$test_dir/main.swift" <<'PYTEST'
from pathlib import Path
import sys
source = Path('Apple/Shared/TimelineGridView.swift').read_text()
divider_start = source.index('struct MixerResizeHandle:')
Path(sys.argv[1]).with_name('divider.swift').write_text('import SwiftUI\nimport AppKit\n' + source[divider_start:source.index('\n#endif', divider_start)])
start = source.index('    private func beginNormalize(')
end = source.index('    private func previewItemEdit(', start)
notification = next(line.strip() for line in source.splitlines() if '.onReceive(show.$normalizeItemsRequest.dropFirst())' in line)
tests = Path('Tests/Apple/GridHostingIntegrationTests.swift').read_text()
tests = tests.replace('NORMALIZATION_NOTIFICATION', notification)
zoom = source[source.index('private final class TimelineZoomState:'):source.index('private struct TimelineViewportLayer<')]
limits = source[source.index('enum TimelineZoomLimits'):source.index('private let markerLaneHeight')]
Path(sys.argv[1]).write_text(limits + zoom + tests + '\nextension NormalizationFixtureContent {\n' + source[start:end] + '\n}\n')
PYTEST
swiftc -swift-version 5 Apple/Shared/NativeTooltips.swift Apple/Shared/NativeTimelineInputGate.swift Apple/Shared/GridSelectionInput.swift Apple/Shared/GridScrollView.swift "$test_dir/environment.swift" "$test_dir/divider.swift" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
