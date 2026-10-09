#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-offline-instrument.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
plugin="$test_dir/GainFixture.vst3"
mkdir -p "$plugin/Contents/MacOS"
cat > "$plugin/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.jaras.test.gain</string><key>CFBundleExecutable</key><string>GainFixture</string><key>CFBundlePackageType</key><string>BNDL</string></dict></plist>
PLIST
clang++ -std=c++17 -fPIC -bundle -ICore/ThirdParty/VST3 Tests/Apple/VST3/GainFixture.cpp \
  Core/ThirdParty/VST3/pluginterfaces/base/funknown.cpp Core/ThirdParty/VST3/pluginterfaces/base/ustring.cpp \
  -framework CoreFoundation -o "$plugin/Contents/MacOS/GainFixture"
JARAS_TEST_VST3="$plugin" CATLIVE_EXPORT_TEST_SOURCE=Tests/Apple/OfflineInstrumentMixTests.swift bash scripts/test-offline-export.sh
