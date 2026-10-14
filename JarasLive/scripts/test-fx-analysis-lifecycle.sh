#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-fx-analysis.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
ulimit -c 0
clang++ -std=c++17 -fobjc-arc -c Apple/Bridge/JarasEffects.mm -o "$build_dir/effects.o"
clang++ -std=c++17 -fobjc-arc -c Apple/Bridge/JarasStemSeparator.mm -o "$build_dir/stemseparator.o"
bash scripts/compile-vst3.sh "$build_dir"
cp "${JARAS_FX_ANALYSIS_TEST_SOURCE:-Tests/Apple/FXAnalysisLifecycleTests.swift}" "$build_dir/main.swift"
swiftc -swift-version 5 -import-objc-header Apple/Bridge/JarasLive-Bridging-Header.h \
    Application/Project/OutputPatch.swift Application/Project/NativeFXSettings.swift \
    Application/Project/TrackRouting.swift Application/Project/MultiLoop.swift \
    Application/Project/TrackAutomation.swift Application/Controls/NativeFXParameter.swift \
    Application/Project/ProjectModels.swift Application/Project/MIDIItem.swift \
    Application/Project/TimelineTempo.swift "${JARAS_FX_ANALYSIS_CHAIN_SOURCE:-Apple/Shared/NativeEffectsChain.swift}" \
    Apple/Shared/CatStemRealtimeRuntime.swift "$build_dir/main.swift" \
    "$build_dir/effects.o" "$build_dir/stemseparator.o" "$build_dir"/vst3*.o \
    -framework Accelerate -lc++ -o "$build_dir/test"
"$build_dir/test"
JARAS_TEST_SAMPLE_RATE=48000 "$build_dir/test"
