#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-item-cpu.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
cp Tests/Apple/ItemChainPerformanceTests.swift "$build_dir/main.swift"
python3 - "$build_dir/chain.swift" <<'PYBENCH'
from pathlib import Path
import sys
source = Path('Apple/Shared/NativeEffectsChain.swift').read_text()
# Recreate the old two-AU item path only in this benchmark. DSP, buffers,
# bypass state and every other processor are identical in both measurements.
source = source.replace('if reorderable {\n            equalizer', 'if reorderable || ProcessInfo.processInfo.environment["CATLIVE_BENCHMARK_SEPARATE"] == "1" {\n            equalizer', 1)
Path(sys.argv[1]).write_text(source)
PYBENCH

clang++ -O2 -std=c++17 -fobjc-arc -c Apple/Bridge/JarasEffects.mm -o "$build_dir/effects.o"
bash scripts/compile-vst3.sh "$build_dir"

swiftc -O -swift-version 5 -import-objc-header Apple/Bridge/JarasLive-Bridging-Header.h Application/Project/OutputPatch.swift Application/Project/NativeFXSettings.swift Application/Project/TrackRouting.swift Application/Project/MultiLoop.swift Application/Project/ProjectModels.swift Application/Project/MIDIItem.swift Application/Project/TimelineTempo.swift "$build_dir/chain.swift" Apple/Shared/EQRealTimeAnalysis.swift "$build_dir/main.swift" "$build_dir/effects.o" "$build_dir"/vst3*.o -lc++ -o "$build_dir/test"
# Alternate A/B order to reduce warm-up and CPU-frequency bias.
for variant in 1 0 0 1; do
 CATLIVE_BENCHMARK_SEPARATE="$variant" "$build_dir/test"
done
