#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-subplay-selection.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT
python3 - "$fixture_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source=Path('Apple/Shared/SongListView.swift').read_text()
a=source.index('private struct SubplayTrackSelectionRequest:')
editor=source[a:].replace('.background(JarasTheme.background)', '.background(JarasTheme.background).background(SubplaySelectionProbe(selection: $selected, apply: { apply(selected) }, cancel: cancel))')
Path(sys.argv[1]).write_text(Path('Tests/Apple/SubplayTrackSelectionTests.swift').read_text()+'\n'+editor)
PY
swiftc -swift-version 5 -default-isolation MainActor -I .build/out/Products/Debug -L .build/out/Products/Debug -lJarasApplication "$fixture_dir/main.swift" -o "$fixture_dir/test"
"$fixture_dir/test"
