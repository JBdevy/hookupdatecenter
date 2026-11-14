#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-pcm-requests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
root = Path.cwd()
source = (root/'Apple/Bridge/JarasPreparedClip.inc').read_text()
source = source[source.index('namespace {'):source.index('struct PreparedClipKernel {')]
source = source.replace('if (readyRequest && *readyRequest == request)', 'if (!FixtureStats::disableHits && readyRequest && *readyRequest == request)')
source = source.replace('if (pages.retiredCount() != 0) pages.collectRetired();', 'FixtureStats::hit();\n            if (pages.retiredCount() != 0) pages.collectRetired();')
source = source.replace('const PreparedPCMPage* producerPageAt(int64_t first) const {', 'const PreparedPCMPage* producerPageAt(int64_t first) const {\n        FixtureStats::lookup();')
Path(sys.argv[1], 'prepared-cache.inc').write_text('#include "' + str(root/'Core/Audio/SingleReaderSlots.hpp') + '"\n' + source + '\n}\n')
PY
export MACOSX_DEPLOYMENT_TARGET=12.0
clang++ -O2 -std=c++17 -fobjc-arc -DCATLIVE_CACHE_DIAGNOSTICS=1 -fsanitize=address,undefined \
  -I"$test_dir" Tests/Apple/PreparedPCMRequestTests.mm -framework AVFoundation -framework Foundation -o "$test_dir/test"
ASAN_OPTIONS=detect_leaks=0 "$test_dir/test"
clang++ -O2 -std=c++17 -fobjc-arc -DCATLIVE_CACHE_DIAGNOSTICS=0 \
  -I"$test_dir" Tests/Apple/PreparedPCMRequestTests.mm -framework AVFoundation -framework Foundation -o "$test_dir/benchmark"
for count in 64 256 512; do
  "$test_dir/benchmark" baseline "$count"
  "$test_dir/benchmark" cached "$count"
done
