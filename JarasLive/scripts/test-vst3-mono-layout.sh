#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_build="$(mktemp -d "${TMPDIR:-/tmp}/catlive-vst3-mono.XXXXXX")"
trap 'rm -rf "$test_build"' EXIT
for channels in 1 6; do
    plugin="$test_build/Channels$channels.vst3"
    mkdir -p "$plugin/Contents/MacOS"
    cat > "$plugin/Contents/Info.plist" <<PLIST
<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.catlive.test.channels$channels</string><key>CFBundleExecutable</key><string>GainFixture</string><key>CFBundlePackageType</key><string>BNDL</string></dict></plist>
PLIST
    clang++ -std=c++17 -fPIC -bundle -fsanitize=address,undefined -fno-sanitize-recover=all \
        -DCATLIVE_FIXTURE_CHANNELS="$channels" \
        -ICore/ThirdParty/VST3 Tests/Apple/VST3/GainFixture.cpp \
        Core/ThirdParty/VST3/pluginterfaces/base/funknown.cpp \
        Core/ThirdParty/VST3/pluginterfaces/base/ustring.cpp -framework CoreFoundation \
        -o "$plugin/Contents/MacOS/GainFixture"
done
clang++ -std=c++17 -fobjc-arc -fsanitize=address,undefined -fno-sanitize-recover=all \
    -ICore/ThirdParty/VST3 Tests/Apple/VST3/MonoLayoutTests.mm \
    Core/ThirdParty/VST3/pluginterfaces/base/*.cpp \
    -framework AVFoundation -framework AppKit -framework AudioToolbox \
    -o "$test_build/test"
"$test_build/test" "$test_build/Channels1.vst3" "$test_build/Channels6.vst3"
