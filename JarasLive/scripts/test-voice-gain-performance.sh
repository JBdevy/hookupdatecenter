#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-voice-gain.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
clang++ -O2 -std=c++17 -fobjc-arc -c Apple/Bridge/JarasEffects.mm -o "$build_dir/effects.o"
bash scripts/compile-vst3.sh "$build_dir"
cp Tests/Apple/VoiceGainPerformanceTests.swift "$build_dir/main.swift"
swiftc -O -swift-version 5 -import-objc-header Apple/Bridge/JarasLive-Bridging-Header.h Application/Project/OutputPatch.swift Application/Project/NativeFXSettings.swift Application/Project/TrackRouting.swift Application/Project/MultiLoop.swift Application/Project/ProjectModels.swift Application/Project/MIDIItem.swift Application/Project/TimelineTempo.swift Apple/Shared/NativeEffectsChain.swift Apple/Shared/EQRealTimeAnalysis.swift "$build_dir/main.swift" "$build_dir/effects.o" "$build_dir"/vst3*.o -framework Accelerate -lc++ -o "$build_dir/test"
for voices in mixed active; do
    args=(--mixed)
    if [[ "$voices" == active ]]; then args+=(--all-active); fi
    "$build_dir/test" --legacy "${args[@]}"
    "$build_dir/test" "${args[@]}"
    "$build_dir/test" "${args[@]}"
    "$build_dir/test" --legacy "${args[@]}"
done
