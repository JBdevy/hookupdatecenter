#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-audio.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
for source in Core/ThirdParty/Lame/*.c; do
 clang -O2 -DHAVE_CONFIG_H -ICore/ThirdParty/Lame -c "$source" -o "$build_dir/$(basename "$source" .c).o"
done
clang++ -std=c++17 -fobjc-arc -c Apple/Bridge/JarasRecording.mm -o "$build_dir/recording.o"
clang++ -std=c++17 -fobjc-arc -c Apple/Bridge/JarasCoreBridge.mm -o "$build_dir/bridge.o"
clang++ -std=c++17 -c Core/Project/Models.cpp -o "$build_dir/models.o"
clang++ -std=c++17 -c Core/Transport/Engine.cpp -o "$build_dir/engine.o"
clang++ -std=c++17 -c Core/Import/TrackTaxonomy.cpp -o "$build_dir/taxonomy.o"
clang++ -std=c++17 -fobjc-arc -c Apple/Bridge/JarasEffects.mm -o "$build_dir/effects.o"
bash scripts/compile-vst3.sh "$build_dir"
clang++ -std=c++17 -fobjc-arc -c Apple/Bridge/JarasSoundFont.mm -o "$build_dir/soundfont.o"
clang++ -std=c++17 -fobjc-arc -c Apple/Bridge/JarasTimecode.mm -o "$build_dir/timecode.o"
cp Tests/Apple/OfflineAudioExportTests.swift "$build_dir/main.swift"
swiftc -swift-version 5 -import-objc-header Apple/Bridge/JarasLive-Bridging-Header.h Application/Export/AudioExportPlan.swift Application/Project/OutputPatch.swift Application/Project/NativeFXSettings.swift Application/Project/TrackRouting.swift Application/Project/MultiLoop.swift Application/Project/ProjectModels.swift Application/Project/TimelineTempo.swift Apple/Shared/AudioDeviceSettings.swift Apple/Shared/NativeTooltips.swift Application/Project/MediaFileNames.swift Application/Project/StemProjectImporter.swift Application/Project/HookImportRules.swift Apple/Shared/MediaProcessingSettings.swift Apple/Shared/ItemReRender.swift Apple/Shared/OfflineAudioExport.swift Apple/Shared/NativeEffectsChain.swift Apple/Shared/VideoMediaSettings.swift Apple/Shared/StemAudioPlayback.swift Apple/Shared/Theme.swift Apple/Shared/InstrumentLibrary.swift "$build_dir/main.swift" "$build_dir"/*.o -lc++ -o "$build_dir/test"
"$build_dir/test"

