#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-compact-mixer.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
python3 - "$build_dir/main.swift" <<'PY'
from pathlib import Path
import sys
s = Path('Apple/Shared/TrackMixerRow.swift').read_text()
def declaration(start):
    first = s.index(start)
    return s[first:s.index('\n}', first) + 2]
geometry = declaration('private final class FooterMixerStripGeometryView:')
layout = declaration('private struct FooterMixerStripLayout {')
submenu = declaration('@MainActor private final class FooterPluginSubmenu:')
fixture = Path('Tests/Apple/FooterMixerCompactSlotsTests.swift').read_text()
Path(sys.argv[1]).write_text(fixture.replace('// PRODUCTION_CHANNEL_GEOMETRY', '\n'.join([layout, geometry, submenu])))
PY
swiftc "$build_dir/main.swift" -o "$build_dir/test"
"$build_dir/test"
