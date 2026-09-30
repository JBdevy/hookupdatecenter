#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-normalization.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
clang -O2 -c Core/ThirdParty/EBUR128/ebur128.c -o "$build_dir/meter.o"
python3 - "$build_dir/Analysis.swift" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_text(Path('Apple/Shared/ItemNormalization.swift').read_text().split('struct ItemNormalizationEditor: View')[0])
PY
cp Tests/Apple/NormalizationTests.swift "$build_dir/main.swift"
swiftc -O -swift-version 5 -import-objc-header Core/ThirdParty/EBUR128/ebur128.h Application/Project/{ProjectModels,TimelineTempo,OutputPatch,TrackRouting,NativeFXSettings}.swift "$build_dir/Analysis.swift" "$build_dir/main.swift" "$build_dir/meter.o" -o "$build_dir/test"
"$build_dir/test"
