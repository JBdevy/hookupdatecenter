#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-recording.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
python3 - "$build_dir/Writer.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/TrackRecording.swift').read_text()
source = source[:source.index('@MainActor final class TrackRecording')]
source = source.replace('private struct', 'struct').replace('private final class CaptureWriter','final class CaptureWriter')
live = Path('Apple/Shared/LiveRecordingPreview.swift').read_text()
live = live[live.index('final class LiveRecordedWaveform'):]
stub = 'import Darwin\n@MainActor final class LiveRecordingPreview: ObservableObject { static let shared = LiveRecordingPreview() }\n'
Path(sys.argv[1]).write_text(source + stub + live + Path('Application/Project/RecordingOverview.swift').read_text() + Path('Apple/Shared/TimelineAudioWaveform.swift').read_text() + Path('Apple/Shared/OfflineAudioExport.swift').read_text())
PY
cp Tests/Apple/RecordingTests.swift "$build_dir/main.swift"
cp -R Apple/Resources/en.lproj Apple/Resources/pt-BR.lproj "$build_dir/"
CATLIVE_EXPORT_TEST_SOURCE="$build_dir/main.swift" CATLIVE_EXPORT_RENDER_SOURCE="$build_dir/Writer.swift" bash scripts/test-offline-plugin-latency.sh
