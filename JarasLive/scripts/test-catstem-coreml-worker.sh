#!/bin/bash
set -euo pipefail
CATSTEM_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CATSTEM_MODEL="${CATSTEM_TEST_MODEL:-$CATSTEM_ROOT/build/CatStemCoreML/Compiled/CatStemHTDemucs6.mlmodelc}"
CATSTEM_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/catstem-coreml-worker.XXXXXX")"
trap 'rm -rf "$CATSTEM_BUILD"' EXIT
python3 - "$CATSTEM_ROOT" "$CATSTEM_BUILD" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
source = (root / 'Apple/Bridge/JarasStemSeparator.mm').read_text()
start = source.index('namespace CatStemRealtime {')
end = source.index('#if TARGET_OS_OSX\nstd::atomic<bool> workerLease', start)
(out / 'CatStemCoreMLTestKernel.hpp').write_text(source[start:end] + '\n#include "CatStemCoreMLRuntime.inc"\n}\n')
PY
xcrun clang++ -std=c++17 -O2 -fobjc-arc -mmacosx-version-min=13.0 \
  -I "$CATSTEM_ROOT/Apple/Bridge" -I "$CATSTEM_BUILD" \
  "$CATSTEM_ROOT/Tests/Apple/CatStemCoreMLWorkerTests.mm" \
  -framework Foundation -framework CoreML -framework AVFoundation -framework Accelerate \
  -o "$CATSTEM_BUILD/test-coreml-worker"
"$CATSTEM_BUILD/test-coreml-worker" "$CATSTEM_MODEL"
