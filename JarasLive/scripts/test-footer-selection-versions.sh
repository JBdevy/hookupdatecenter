#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-footer-selection.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source=Path('Apple/Shared/TrackMixerRow.swift').read_text()
state=source[source.index('private struct FooterMixerRenderState:'):source.index('struct FooterHorizontalMixer:')]
versions=source[source.index('private final class FooterMixerStripVersions'):source.index('private struct FooterMixerContent:')]
tests=Path('Tests/Apple/FooterMixerSelectionVersionsTests.swift').read_text()
Path(sys.argv[1]).write_text(tests.replace('// INSERT_RENDER_STATE',state).replace('// INSERT_STRIP_VERSIONS',versions))
PY
swiftc "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
