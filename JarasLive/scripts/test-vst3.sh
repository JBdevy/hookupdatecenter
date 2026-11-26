#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-vst3.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
plugin="$build_dir/GainFixture.vst3"
mkdir -p "$plugin/Contents/MacOS"
cat > "$plugin/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.jaras.test.gain</string><key>CFBundleExecutable</key><string>GainFixture</string><key>CFBundlePackageType</key><string>BNDL</string></dict></plist>
PLIST
clang++ -std=c++17 -fPIC -bundle -ICore/ThirdParty/VST3 Tests/Apple/VST3/GainFixture.cpp Core/ThirdParty/VST3/pluginterfaces/base/funknown.cpp Core/ThirdParty/VST3/pluginterfaces/base/ustring.cpp -framework CoreFoundation -o "$plugin/Contents/MacOS/GainFixture"
bash scripts/compile-vst3.sh "$build_dir"
clang++ -std=c++17 -fobjc-arc Tests/Apple/VST3/AudioUnitHostTests.mm "$build_dir"/*.o \
    -framework AppKit -framework AVFoundation -framework AudioToolbox -framework CoreAudioKit -framework CoreAudio \
    -o "$build_dir/audio-unit-test"
"$build_dir/audio-unit-test"
cp Tests/Apple/VST3/HostTests.swift "$build_dir/main.swift"
swiftc -swift-version 5 -import-objc-header Apple/Bridge/JarasVST3.h "$build_dir/main.swift" "$build_dir"/*.o -framework Accelerate -lc++ -o "$build_dir/test"
"$build_dir/test" "$plugin"

clang++ -std=c++17 -fobjc-arc -c Apple/Bridge/JarasEffects.mm -o "$build_dir/effects.o"
clang++ -std=c++17 -fobjc-arc -c Apple/Bridge/JarasCatSynth.mm -o "$build_dir/catsynth.o"
clang++ -std=c++17 -fobjc-arc -c Apple/Bridge/JarasStemSeparator.mm -o "$build_dir/stemseparator.o"
bash scripts/prepare-drummer-test-support.sh "$build_dir"
cp Tests/Apple/VST3/OrderedChainTests.swift "$build_dir/main.swift"
swiftc -swift-version 5 -import-objc-header Apple/Bridge/JarasLive-Bridging-Header.h Application/Project/OutputPatch.swift Application/Project/DrummerPadKit.swift Application/Project/NativeFXSettings.swift Application/Project/TrackRouting.swift Application/Project/MultiLoop.swift Application/Project/TrackAutomation.swift Application/Controls/NativeFXParameter.swift Application/Project/ProjectModels.swift Application/Project/MIDIItem.swift Application/Project/ItemFade.swift Application/Project/ItemFadeCurve.swift Application/Project/TimelineTempo.swift Apple/Shared/NativeEffectsChain.swift Apple/Shared/DrummerPadAudio.swift Application/Project/AudioFileRead.swift "$build_dir/DrummerPadSupport.swift" Apple/Shared/CatStemRealtimeRuntime.swift "$build_dir/main.swift" "$build_dir"/*.o -framework Accelerate -lc++ -o "$build_dir/ordered-test"
"$build_dir/ordered-test" "$plugin"
JARAS_TEST_VST3="$plugin" bash scripts/test-audio.sh \
    Tests/Apple/VST3/StandbyMeterTests.swift Tests/Apple/AutomationAudioTests.swift
