#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-windows-timer.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/test.cpp" <<'PY'
from pathlib import Path
import sys
state = Path('Windows/Source/StageState.h').read_text()
constructor = state[state.index('    explicit StageState('):state.index('    Appearance &preferences;')]
methods = state[state.index('    static double now()'):state.index('    void observe(')]
remote = Path('Windows/Source/RemotePresentation.h').read_text()
handler = remote[remote.index('        if (a == "timerStart" ||'):remote.index('        if (a == "noticeSend" ||')]
source = Path('Tests/Core/WindowsStageTimerTests.cpp').read_text()
source = source.replace('// INSERT_CONSTRUCTOR', constructor).replace('// INSERT_TIMER_METHODS', methods).replace('// INSERT_REMOTE_HANDLER', handler)
Path(sys.argv[1]).write_text(source)
PY
"${CXX:-clang++}" -std=c++17 -Wall -Wextra -pedantic "$test_dir/test.cpp" -o "$test_dir/test"
"$test_dir/test"
