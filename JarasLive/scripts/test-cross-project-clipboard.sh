#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-cross-project-clipboard.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
# Exercise the production Windows selection/mapping code on the Mac too.
# Only the platform-heavy Common.h and UUID provider are replaced.
python3 - "$test_dir/clipboard-under-test.hpp" <<'PY'
from pathlib import Path
import sys
source = Path('Windows/Source/GridItemClipboard.h').read_text()
dependencies = '''#include "Core/Project/Models.hpp"
#include <map>
#include <set>
#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>
namespace catlive { using jaras::ID; inline ID uuid() { static int next = 0; return "new-" + std::to_string(++next); } }
'''
Path(sys.argv[1]).write_text(source.replace('#include "Common.h"', dependencies))
PY
clang++ -std=c++17 -fsanitize=address,undefined -I. -I"$test_dir" Tests/Core/CrossProjectClipboardTests.cpp \
    Core/Project/Models.cpp Core/Import/TrackTaxonomy.cpp -o "$test_dir/test"
"$test_dir/test"
swift test --filter GridItemClipboardTests
bash scripts/test-grid-media-clipboard.sh
