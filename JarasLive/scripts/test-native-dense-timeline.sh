#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d "${TMPDIR:-/tmp}/catlive-native-dense.XXXXXX")"
trap 'rm -rf "$work"' EXIT
python3 - "$work/main.swift" <<'PYTEST'
from pathlib import Path
import sys
view=Path('Apple/Shared/DAWRemoteView.swift').read_text()
cache=view[view.index('private final class IpadTimelineContentCache {'):view.index('/// The center grid renders native clip geometry')]
models=Path('Application/Project/ProjectModels.swift').read_text()
lanes=models[models.index('public struct TrackLanes:'):models.index('public enum TrackKind:')]
Path(sys.argv[1]).write_text('import Foundation\n'+Path('Tests/Apple/NativeDenseTimelineFixture.swift').read_text()+lanes+cache+Path('Tests/Apple/NativeDenseTimelineTests.swift').read_text())
PYTEST
swiftc -O -swift-version 5 Apple/Shared/TimelineVisibleClipIndex.swift "$work/main.swift" -o "$work/test"
"$work/test"
