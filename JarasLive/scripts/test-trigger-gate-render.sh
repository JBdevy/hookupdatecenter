#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-effects.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
clang++ -std=c++17 -fobjc-arc -c Apple/Bridge/JarasEffects.mm -o "$build_dir/effects.o"
clang++ -std=c++17 -fobjc-arc -c Apple/Bridge/JarasStemSeparator.mm -o "$build_dir/stemseparator.o"
bash scripts/compile-vst3.sh "$build_dir"
cp Tests/Apple/TriggerGateRenderTests.swift "$build_dir/main.swift"
swiftc -Onone -swift-version 5 -import-objc-header Apple/Bridge/JarasLive-Bridging-Header.h Application/Project/OutputPatch.swift Application/Project/NativeFXSettings.swift Application/Project/TrackRouting.swift Application/Project/MultiLoop.swift Application/Project/TrackAutomation.swift Application/Controls/NativeFXParameter.swift Application/Project/ProjectModels.swift Application/Project/MIDIItem.swift Application/Project/ItemFade.swift Application/Project/ItemFadeCurve.swift Application/Project/TimelineTempo.swift Apple/Shared/NativeEffectsChain.swift Apple/Shared/CatStemRealtimeRuntime.swift Apple/Shared/EQRealTimeAnalysis.swift "$build_dir/main.swift" "$build_dir/effects.o" "$build_dir/stemseparator.o" "$build_dir"/vst3*.o -framework Accelerate -lc++ -o "$build_dir/test"
for rate in 44100 48000; do JARAS_TEST_SAMPLE_RATE="$rate" "$build_dir/test"; done
