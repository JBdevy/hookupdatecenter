#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-windows-remote-tuning.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
out=Path(sys.argv[1])
source=Path('Windows/Source/RemotePresentation.h').read_text()
start=source.index('        if (const auto *part = song ? regionPitch::target(')
end=source.index('        const auto *tempoRegion',start)
snapshot=source[start:end]
start=source.index('        if (a == "tempo") {')
commands=source[start:source.index('        if (a == "editRegion") {',start)]
test=Path('Tests/Core/WindowsRemoteTuningTests.cpp').read_text()
(out/'test.cpp').write_text(test.replace('// INSERT_PITCH_SNAPSHOT',snapshot).replace('// INSERT_TUNING_COMMANDS',commands))
# Region targeting and target defaults are the actual production header; only
# its Windows/JUCE include is replaced with the same portable Core model types.
header=Path('Windows/Source/RegionPitch.h').read_text().replace('#include "Common.h"',
    '#include "Songs/Song.hpp"\n#include "Transport/TransportState.hpp"\n#include <algorithm>\nnamespace catlive { using jaras::ID; }')
(out/'RemotePitchForTest.h').write_text(header)
PY
"${CXX:-clang++}" -std=c++17 -Wall -Wextra -Wno-missing-field-initializers -pedantic -I Core "$test_dir/test.cpp" -o "$test_dir/test"
"$test_dir/test"
