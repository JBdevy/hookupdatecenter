#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-audio.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
cxx_options=()
swift_options=()
if [[ "${CATLIVE_EXPORT_TEST_OPTIMIZED:-0}" == "1" ]]; then
 cxx_options=(-O2)
 swift_options=(-O -whole-module-optimization)
fi
for source in Core/ThirdParty/Lame/*.c; do
 clang -O2 -DHAVE_CONFIG_H -ICore/ThirdParty/Lame -c "$source" -o "$build_dir/$(basename "$source" .c).o"
done
clang++ ${cxx_options[@]+"${cxx_options[@]}"} -std=c++17 -fobjc-arc -c Apple/Bridge/JarasRecording.mm -o "$build_dir/recording.o"
clang++ ${cxx_options[@]+"${cxx_options[@]}"} -std=c++17 -fobjc-arc -c Apple/Bridge/JarasCoreBridge.mm -o "$build_dir/bridge.o"
clang++ ${cxx_options[@]+"${cxx_options[@]}"} -std=c++17 -c Core/Project/Models.cpp -o "$build_dir/models.o"
clang++ ${cxx_options[@]+"${cxx_options[@]}"} -std=c++17 -c Core/Transport/Engine.cpp -o "$build_dir/engine.o"
clang++ ${cxx_options[@]+"${cxx_options[@]}"} -std=c++17 -c Core/Import/TrackTaxonomy.cpp -o "$build_dir/taxonomy.o"
clang++ ${cxx_options[@]+"${cxx_options[@]}"} -std=c++17 -fobjc-arc -c Apple/Bridge/JarasEffects.mm -o "$build_dir/effects.o"
clang++ ${cxx_options[@]+"${cxx_options[@]}"} -std=c++17 -fobjc-arc -c Apple/Bridge/JarasStemSeparator.mm -o "$build_dir/stemseparator.o"
bash scripts/compile-vst3.sh "$build_dir"
clang++ ${cxx_options[@]+"${cxx_options[@]}"} -std=c++17 -fobjc-arc -c Apple/Bridge/JarasSoundFont.mm -o "$build_dir/soundfont.o"
clang++ ${cxx_options[@]+"${cxx_options[@]}"} -std=c++17 -fobjc-arc -c Apple/Bridge/JarasTimecode.mm -o "$build_dir/timecode.o"
extra_sources=()
if [[ "${CATLIVE_TEST_SEPARATOR:-0}" == "1" ]]; then
 python3 - "$build_dir" <<'PYSEP'
from pathlib import Path
import sys
source = Path('Apple/Shared/CatStemSeparation.swift').read_text()
source = source[:source.index('@MainActor final class CatStemSession')].replace('private enum CatStemRenderer', 'enum CatStemRenderer')
Path(sys.argv[1], 'separator.swift').write_text(source + '\n#endif\n')
PYSEP
 swift_options+=(-parse-as-library)
 extra_sources=(Application/Project/StemSeparation.swift "$build_dir/separator.swift")
fi
if [[ "${CATLIVE_TEST_REDUCTION:-0}" == "1" ]]; then
 extra_sources+=(Application/Project/ProjectEditing.swift Application/Project/ProjectReduction.swift Apple/Shared/ReducedProjectWriter.swift)
fi
cp "${CATLIVE_EXPORT_TEST_SOURCE:-Tests/Apple/OfflineAudioExportTests.swift}" "$build_dir/main.swift"
swiftc ${swift_options[@]+"${swift_options[@]}"} -swift-version 5 -import-objc-header Apple/Bridge/JarasLive-Bridging-Header.h Application/Licensing/AudioLicenseAccess.swift Application/Account/AccountModels.swift Application/Project/AudioFileRead.swift Application/Export/AudioExportPlan.swift Application/Project/OutputPatch.swift Application/Project/NativeFXSettings.swift Application/Project/TrackRouting.swift Application/Project/MultiLoop.swift Application/Project/TrackAutomation.swift Application/Controls/NativeFXParameter.swift Application/Project/ProjectModels.swift Application/Project/MIDIItem.swift Application/Project/ItemFade.swift Application/Project/ItemFadeCurve.swift Application/Project/ItemGlue.swift Application/Project/TimelineTempo.swift Apple/Shared/AudioDeviceSettings.swift Apple/Shared/NativeTooltips.swift Application/Project/MediaFileNames.swift Application/Project/ProjectDocumentCodec.swift Application/Project/ProjectDocumentAppearance.swift Application/Project/StemProjectImporter.swift Application/Project/HookImportRules.swift Apple/Shared/MediaProcessingSettings.swift Apple/Shared/ItemReRender.swift "${CATLIVE_EXPORT_RENDER_SOURCE:-Apple/Shared/OfflineAudioExport.swift}" Apple/Shared/NativeEffectsChain.swift Apple/Shared/CatStemRealtimeRuntime.swift Apple/Shared/VideoMediaSettings.swift Application/Project/ClickTrack.swift Apple/Shared/ClickAudioSample.swift Apple/Shared/StemAudioPlayback.swift Apple/Shared/Theme.swift Apple/Shared/InstrumentLibrary.swift ${extra_sources[@]+"${extra_sources[@]}"} "$build_dir/main.swift" "$build_dir"/*.o -framework Accelerate -lc++ -o "$build_dir/test"
cp -R Apple/Resources/en.lproj Apple/Resources/pt-BR.lproj "$build_dir/"
if [[ -n "${CATLIVE_EXPORT_TEST_BINARY:-}" ]]; then
 cp "$build_dir/test" "$CATLIVE_EXPORT_TEST_BINARY"
fi
if [[ "${CATLIVE_EXPORT_TEST_BUILD_ONLY:-0}" != "1" ]]; then
 "$build_dir/test"
fi

