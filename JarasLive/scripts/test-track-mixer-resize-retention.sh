#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-mixer-retention.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
sys.path.insert(0, 'scripts')
from native_mixer_test_sources import native_mixer_sources
root=Path(sys.argv[1]);parts=native_mixer_sources()
parts.append(Path('Tests/Apple/TrackMixerResizeRetentionTests.swift').read_text())
tests=Path('Tests/Apple/TrackMixerNativeControlsTests.swift').read_text()
tests=tests.replace('.buttonStyle(CompactTrackButtonStyle()).background {', '.buttonStyle(CompactTrackButtonStyle()).background(TrackControlSelectionExclusion()).background {')
tests=tests.replace('_ = NSApplication.shared\nif CommandLine.arguments', '_ = NSApplication.shared\nif CommandLine.arguments.contains("--resize-retention") { if CommandLine.arguments.contains("--verify-retention") { verifyDetachedRetention() } else { verifyResizeRetention() }; return }\nif CommandLine.arguments')
parts.append(tests)
source='\n'.join(parts)
# Test-only baseline retains the formerly hidden hosts. Candidate runs the
# production detachment implementation unchanged.
source=source.replace('    private func setHostsAttached(_ attached: Bool) {',
    '    private func setHostsAttached(_ attached: Bool) {\n        if CommandLine.arguments.contains("--keep-offscreen-attached") { return }')
root.joinpath('main.swift').write_text(source)
PY
swiftc -swift-version 5 Apple/Shared/NativeTimelineInputGate.swift -O -target "$(uname -m)-apple-macos12.0" Apple/Shared/JarasLegacyLayout.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test" --resize-retention --verify-retention --behavior
for pass in 1 2 3; do
    "$test_dir/test" --resize-retention --keep-offscreen-attached
    "$test_dir/test" --resize-retention
done
