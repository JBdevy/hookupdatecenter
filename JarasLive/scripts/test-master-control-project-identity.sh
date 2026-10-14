#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-master-control-identity.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import os, sys
source = Path(os.environ.get('CATLIVE_TRACK_MIXER_SOURCE', 'Apple/Shared/TrackMixerRow.swift')).read_text()
start = source.index('private struct TrackPanFader:')
end = source.index('/// One insertion indicator', start)
identity_start = source.index('private struct TrackControlIdentity:')
identity = source[identity_start:source.index('\nstruct TrackMixerRow:', identity_start)]
# Keep the complete production SwiftUI wrappers, captured callbacks, native
# slider, rebind and teardown. Only backend commands/unopened menus are stubbed.
support = Path('Tests/Apple/MasterControlProjectIdentityTests.swift').read_text()
Path(sys.argv[1]).write_text('import AppKit\nimport SwiftUI\nimport Combine\n' + identity + '\n' + source[start:end] + '\n' + support)
PY
swiftc -swift-version 5 -target "$(uname -m)-apple-macos12.0" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
