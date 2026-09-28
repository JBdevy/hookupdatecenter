#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-effects.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
clang++ -std=c++17 -fobjc-arc -c Apple/Bridge/JarasEffects.mm -o "$build_dir/effects.o"
bash scripts/compile-vst3.sh "$build_dir"
cp Tests/Apple/EffectsTests.swift "$build_dir/main.swift"
swiftc -Onone -swift-version 5 -import-objc-header Apple/Bridge/JarasLive-Bridging-Header.h Application/Project/OutputPatch.swift Application/Project/NativeFXSettings.swift Application/Project/TrackRouting.swift Application/Project/ProjectModels.swift Application/Project/TimelineTempo.swift Apple/Shared/NativeEffectsChain.swift Apple/Shared/EQRealTimeAnalysis.swift "$build_dir/main.swift" "$build_dir/effects.o" "$build_dir"/vst3*.o -lc++ -o "$build_dir/test"
"$build_dir/test"
