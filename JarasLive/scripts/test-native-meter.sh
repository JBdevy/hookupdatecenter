#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-native-meter.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source=Path('Apple/Shared/StemAudioPlayback.swift').read_text()
model=source[source.index('@MainActor final class TrackMeterLevel'):source.index('/// Item edges')]
native=source[source.index('/// Uses the existing stereo readings'):source.index('private final class PreparedSoundFont')]
models=Path('Application/Project/ProjectModels.swift').read_text()
kind=models[models.index('public enum TrackKind:'):models.index('public extension AudioClip {',models.index('public enum TrackKind:'))]
row=Path('Apple/Shared/TrackMixerRow.swift').read_text()
policy_start=row.index('private func trackShowsMeterReadouts(')
policy=row[policy_start:row.index('\n}', policy_start)+2]
Path(sys.argv[1]).write_text('import SwiftUI\nimport AppKit\nimport Combine\n'+kind+'\n'+policy+'\n'+model+'\n'+native+'\n'+Path('Tests/Apple/NativeVerticalTrackMeterTests.swift').read_text())
PY
swiftc "${JARAS_TEST_OPTIMIZATION:--O}" -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
