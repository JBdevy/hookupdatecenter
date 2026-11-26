#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-native-controls.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
sys.path.insert(0, 'scripts')
from native_mixer_test_sources import native_mixer_sources
root=Path(sys.argv[1]);parts=native_mixer_sources()
parts.append(Path('Tests/Apple/TrackMixerNativeControlsTests.swift').read_text())
root.joinpath('main.swift').write_text('\n'.join(parts))
PY
swiftc -swift-version 5 Apple/Shared/NativeTimelineInputGate.swift -O -target "${CATLIVE_TEST_ARCH:-$(uname -m)}-apple-macos12.0" Apple/Shared/JarasLegacyLayout.swift "$test_dir/main.swift" -o "$test_dir/test"
if [[ "${1:-}" == "--build-only" ]]; then
    cp "$test_dir/test" "${2:?Specify the output binary path}"
    exit 0
fi
"$test_dir/test" --automatic-height
"$test_dir/test" --mode-transition
"$test_dir/test" --geometry
"$test_dir/test" --behavior
if [[ "${1:-}" == "--benchmark" ]]; then
    "$test_dir/test"
    "$test_dir/test" --candidate
fi
