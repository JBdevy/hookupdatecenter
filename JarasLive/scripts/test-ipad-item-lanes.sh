#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-ipad-lanes.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import re, sys
models = Path('Application/Project/ProjectModels.swift').read_text()
lanes = models[models.index('public struct TrackLanes:'):models.index('public struct RegionLanes:')]
view = Path('Apple/Shared/DAWRemoteView.swift').read_text()
geometry = view[view.index('private struct IpadNativeItemGeometry {'):view.index('private struct RemoteTimelineTrackRow:')]
protocol = Path('Apple/Shared/DAWRemoteProtocol.swift').read_text()
selection = Path('Apple/Shared/GridSelectionInput.swift').read_text()
inset = re.search(r'static let verticalInset: CGFloat = [^\n]+', selection).group(0)
height_geometry = models[models.index('public enum TrackHeightGeometry'):models.index('public struct TrackLinkOriginal')]
Path(sys.argv[1]).write_text('import Foundation\n' + '''
public struct AudioClip { var id = UUID(); var startTime: Double; var duration: Double; var recordingLane: Int? }
public struct Track { var clips: [AudioClip]; var kind = FixtureTrackKind() }
public struct FixtureTrackKind { var isTeleprompter = false }
''' + next(line for line in models.splitlines() if line.startswith('public enum ProjectError:')) + '''

''' + Path('Application/Project/TeleprompterSettings.swift').read_text() + protocol + "enum GridSelectionItem { " + inset + " }\n" + height_geometry + lanes + geometry + Path('Tests/Apple/IpadItemLaneTests.swift').read_text())
PY
swiftc -O -swift-version 5 Application/Project/OutputPatch.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
