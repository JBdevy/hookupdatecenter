#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-macos12-layout.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
sys.path.insert(0, 'scripts')
from native_mixer_test_sources import native_mixer_sources
mixer='\n'.join(native_mixer_sources(timeline_rows=False))
mixer=mixer.replace('inputRegistration.update(active: active)', 'TrackMixerRegistrationProbe.calls += 1; inputRegistration.update(active: active)')
grid=Path('Apple/Shared/TimelineGridView.swift').read_text()
start=grid.index('@available(macOS 13, *)\nprivate struct TimelineColumnsLayout:')
grid=grid[start:grid.index('private struct TimelineMixerIdentity',start)]
stubs = 'enum TrackMixerRegistrationProbe { static var calls = 0 }\n'
Path(sys.argv[1]).write_text(stubs + mixer + '\n' + grid + '\n' + Path('Tests/Apple/MacOS12LayoutTests.swift').read_text())

PY
swiftc -swift-version 5 Apple/Shared/NativeTimelineInputGate.swift -target "$(uname -m)-apple-macos12.0" \
  Apple/Shared/JarasLegacyLayout.swift \
  "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
"$test_dir/test" --catlive-test-macos12
