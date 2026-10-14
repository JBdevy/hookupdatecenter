#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_build="$(mktemp -d "${TMPDIR:-/tmp}/catlive-vst3-live-state.XXXXXX")"
trap 'rm -rf "$test_build"' EXIT
plugin="$test_build/GainFixture.vst3"
mkdir -p "$plugin/Contents/MacOS"
cat > "$plugin/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.catlive.test.live-state</string><key>CFBundleExecutable</key><string>GainFixture</string><key>CFBundlePackageType</key><string>BNDL</string></dict></plist>
PLIST
clang++ -std=c++17 -fPIC -bundle -fsanitize=address,undefined -fno-sanitize-recover=all \
    -DCATLIVE_STATE_RESTORE_DIAGNOSTICS \
    -ICore/ThirdParty/VST3 Tests/Apple/VST3/GainFixture.cpp \
    Core/ThirdParty/VST3/pluginterfaces/base/funknown.cpp \
    Core/ThirdParty/VST3/pluginterfaces/base/ustring.cpp -framework CoreFoundation \
    -o "$plugin/Contents/MacOS/GainFixture"
clang++ -std=c++17 -fobjc-arc -fsanitize=address,undefined -fno-sanitize-recover=all \
    -ICore/ThirdParty/VST3 Tests/Apple/VST3/LiveStateRestoreTests.mm \
    Core/ThirdParty/VST3/pluginterfaces/base/*.cpp \
    -framework AVFoundation -framework AppKit -framework AudioToolbox \
    -o "$test_build/test"
separate="$test_build/SeparateController.vst3"
mkdir -p "$separate/Contents/MacOS"
sed 's/com.catlive.test.live-state/com.catlive.test.separate-controller/' "$plugin/Contents/Info.plist" > "$separate/Contents/Info.plist"
clang++ -std=c++17 -fPIC -bundle -fsanitize=address,undefined -fno-sanitize-recover=all \
    -DCATLIVE_STATE_RESTORE_DIAGNOSTICS -DCATLIVE_SEPARATE_CONTROLLER \
    -ICore/ThirdParty/VST3 Tests/Apple/VST3/GainFixture.cpp \
    Core/ThirdParty/VST3/pluginterfaces/base/funknown.cpp \
    Core/ThirdParty/VST3/pluginterfaces/base/ustring.cpp -framework CoreFoundation \
    -o "$separate/Contents/MacOS/GainFixture"
"$test_build/test" "$plugin" "$separate"
