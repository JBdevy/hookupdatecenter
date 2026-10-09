#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-audio.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
clang++ -std=c++17 -fobjc-arc -c Apple/Bridge/JarasCoreBridge.mm -o "$build_dir/bridge.o"
clang++ -std=c++17 -c Core/Project/Models.cpp -o "$build_dir/models.o"
clang++ -std=c++17 -c Core/Transport/Engine.cpp -o "$build_dir/engine.o"
clang++ -std=c++17 -c Core/Import/TrackTaxonomy.cpp -o "$build_dir/taxonomy.o"
clang++ -std=c++17 -fobjc-arc -c Apple/Bridge/JarasEffects.mm -o "$build_dir/effects.o"
clang++ -std=c++17 -fobjc-arc -c Apple/Bridge/JarasStemSeparator.mm -o "$build_dir/stemseparator.o"
bash scripts/compile-vst3.sh "$build_dir"
clang++ -std=c++17 -fobjc-arc -c Apple/Bridge/JarasSoundFont.mm -o "$build_dir/soundfont.o"
clang++ -std=c++17 -fobjc-arc -c Apple/Bridge/JarasTimecode.mm -o "$build_dir/timecode.o"
cp "${JARAS_AUDIO_TEST_SOURCE:-Tests/Apple/AudioRenderTests.swift}" "$build_dir/main.swift"
swiftc -swift-version 5 -import-objc-header Apple/Bridge/JarasLive-Bridging-Header.h Application/Project/OutputPatch.swift Application/Project/NativeFXSettings.swift Application/Project/TrackRouting.swift Application/Project/MultiLoop.swift Application/Project/ProjectModels.swift Application/Project/MIDIItem.swift Application/Project/TimelineTempo.swift Apple/Shared/AudioDeviceSettings.swift Apple/Shared/NativeTooltips.swift Apple/Shared/NativeEffectsChain.swift Apple/Shared/CatStemRealtimeRuntime.swift Apple/Shared/VideoMediaSettings.swift Application/Project/ClickTrack.swift Apple/Shared/ClickAudioSample.swift Application/Project/AudioFileRead.swift Apple/Shared/StemAudioPlayback.swift Apple/Shared/Theme.swift Apple/Shared/InstrumentLibrary.swift "$build_dir/main.swift" "$build_dir/bridge.o" "$build_dir/models.o" "$build_dir/engine.o" "$build_dir/taxonomy.o" "$build_dir/effects.o" "$build_dir/stemseparator.o" "$build_dir/soundfont.o" "$build_dir/timecode.o" "$build_dir"/vst3*.o -framework Accelerate -lc++ -o "$build_dir/test"
"$build_dir/test"
JARAS_TEST_SAMPLE_RATE=48000 "$build_dir/test"
