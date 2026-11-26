#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export MACOSX_DEPLOYMENT_TARGET=12.0
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-idle-graph.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
plugin="$build_dir/GainFixture.vst3"
mkdir -p "$plugin/Contents/MacOS"
cat > "$plugin/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.jaras.test.gain</string><key>CFBundleExecutable</key><string>GainFixture</string><key>CFBundlePackageType</key><string>BNDL</string></dict></plist>
PLIST
clang++ -std=c++17 -fPIC -bundle -ICore/ThirdParty/VST3 Tests/Apple/VST3/GainFixture.cpp Core/ThirdParty/VST3/pluginterfaces/base/funknown.cpp Core/ThirdParty/VST3/pluginterfaces/base/ustring.cpp -framework CoreFoundation -o "$plugin/Contents/MacOS/GainFixture"
CATLIVE_EXPORT_TEST_SOURCE=Tests/Apple/IdleAudioGraphTests.swift \
CATLIVE_EXPORT_TEST_BINARY="$build_dir/test" CATLIVE_EXPORT_TEST_BUILD_ONLY=1 bash scripts/test-offline-export.sh
for rate in 44100 48000; do
    JARAS_TEST_VST3="$plugin" JARAS_TEST_SAMPLE_RATE="$rate" "$build_dir/test"
    JARAS_TEST_VST3="$plugin" JARAS_TEST_SAMPLE_RATE="$rate" "$build_dir/test" --legacy
done
