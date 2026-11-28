#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -e /tmp/catlive-perf-measurement.lock ]]; then
  echo "Performance measurement is active; hosting compilation deferred." >&2
  exit 2
fi
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-grid-hosting.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/environment.swift" <<'PY'
from pathlib import Path
import sys
fx = Path('Apple/Shared/FXEditor.swift').read_text()
text = Path('Apple/Shared/TextItemEditor.swift').read_text()
region = Path('Apple/Shared/RegionEditor.swift').read_text()
track_environment = region[region.index('/// Immutable menu target:'):]
models = Path('Application/Project/ProjectModels.swift').read_text()
geometry = models[models.index('public enum TrackHeightGeometry'):models.index('public struct TrackLinkOriginal')]
elastic = models[models.index('public struct ElasticPoint:'):models.index('public struct AudioClip:')]
theme = Path('Apple/Shared/Theme.swift').read_text()
color_start = theme.index('extension Color {')
color = theme[color_start:theme.index('\n}', color_start) + 2]
appearance = theme.index('enum TimelineAppearanceDefaults {')
appearance = theme[appearance:theme.index('\n}', appearance) + 2]
interface = theme[theme.index('enum JarasInterfaceTheme:'):theme.index('enum JarasTheme {')]
constants = '\n'.join(line for line in theme.splitlines() if line.strip().startswith((
    'static let displayHex:', 'static let lightDarkBackgroundHex:', 'static let workspaceToolbar =',
    'static let setlistQueuedYellow:')))
theme = interface + '\nenum JarasTheme {\n' + constants + '\n}\n'
pads = Path('Apple/Shared/VinhetasPanel.swift').read_text()
transfer = pads[pads.index('enum LibrarySamplerTransfer {'):pads.index('enum PadAudioBuffer {')]
importer = Path('Application/Project/StemProjectImporter.swift').read_text()
media_filter = importer[importer.index('enum GridMediaFileFilter {'):importer.index('/// Runs on a worker task')]
Path(sys.argv[1]).write_text('import UniformTypeIdentifiers\n' + media_filter + geometry + elastic + fx[:fx.index('enum FXModelLookup')] + text[:text.index('/// The draft')] + track_environment + '\n' + appearance + '\n' + color + '\n' + theme + transfer)

PY
python3 - "$test_dir/main.swift" <<'PYTEST'
from pathlib import Path
import sys
source = Path('Apple/Shared/TimelineGridView.swift').read_text()
divider_start = source.index('struct MixerResizeHandle:')
Path(sys.argv[1]).with_name('divider.swift').write_text('import SwiftUI\nimport AppKit\n' + source[divider_start:source.index('\n#endif', divider_start)])
start = source.index('    private func beginNormalize(')
end = source.index('\n    private func', start + 1)
notification = next(line.strip() for line in source.splitlines() if '.onReceive(show.$normalizeItemsRequest.dropFirst())' in line)
tests = Path('Tests/Apple/GridHostingIntegrationTests.swift').read_text()
tests = tests.replace('NORMALIZATION_NOTIFICATION', notification)
tempo_notification = next(line.strip() for line in source.splitlines() if '.onReceive(show.$tempoMarkerRequest.dropFirst())' in line)
tests = tests.replace('TEMPO_NOTIFICATION', tempo_notification)
mount_start = source.index('private struct NativeTimelineBaseSlot:')
mount = source[mount_start:source.index('\n@MainActor private final class NativeTimelineBaseController', mount_start)]
tests += '\n' + mount + '\n' + Path('Tests/Apple/TimelineNativeMountTests.swift').read_text()
zoom = source[source.index('private final class TimelineCoordinatePlane:'):source.index('/// Empty layers keep their content subscriptions')]
limits_start = source.index('enum TimelineZoomLimits')
limits = source[limits_start:source.index('\n}', limits_start) + 2] + '\n'
transport = Path('Apple/Shared/TransportView.swift').read_text()
tool_start = transport.index('enum ProGridTool:')
current_tool = transport.index('    static var current: ProGridTool {', tool_start)
tools = transport[tool_start:transport.index('    @MainActor func apply(', tool_start)] + transport[current_tool:transport.index('\n}', current_tool) + 2] + '\n'
preferences_start = source.index('enum TimelineViewportPreferences {')
preferences = source[preferences_start:source.index('\n}', preferences_start) + 2] + '\n'
Path(sys.argv[1]).write_text(limits + preferences + zoom + tools + tests + '\nextension NormalizationFixtureContent {\n' + source[start:end] + '\n}\n')
PYTEST
swiftc Application/Project/ItemFadeCurve.swift -swift-version 5 Apple/Shared/NativeTooltips.swift Apple/Shared/NativeTimelineInputGate.swift Apple/Shared/GridSelectionInput.swift Apple/Shared/GridScrollView.swift "$test_dir/environment.swift" "$test_dir/divider.swift" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
