#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-plugin-transport.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
clang++ -std=c++17 Tests/Core/PluginTransportTests.cpp Core/Project/Models.cpp Core/Import/TrackTaxonomy.cpp -o "$test_dir/core-test"
"$test_dir/core-test"
plugin="$test_dir/GainFixture.vst3"
mkdir -p "$plugin/Contents/MacOS"
cat > "$plugin/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.jaras.test.transport</string><key>CFBundleExecutable</key><string>GainFixture</string><key>CFBundlePackageType</key><string>BNDL</string></dict></plist>
PLIST
clang++ -std=c++17 -DCATLIVE_TRANSPORT_DIAGNOSTICS -fPIC -bundle -ICore/ThirdParty/VST3 Tests/Apple/VST3/GainFixture.cpp Core/ThirdParty/VST3/pluginterfaces/base/funknown.cpp Core/ThirdParty/VST3/pluginterfaces/base/ustring.cpp -framework CoreFoundation -o "$plugin/Contents/MacOS/GainFixture"
bash scripts/compile-vst3.sh "$test_dir"
cp Tests/Apple/VST3/TransportTests.swift "$test_dir/main.swift"
swiftc -swift-version 5 -import-objc-header Apple/Bridge/JarasVST3.h "$test_dir/main.swift" "$test_dir"/*.o -framework Accelerate -lc++ -o "$test_dir/test"
"$test_dir/test" "$plugin"
JARAS_TEST_VST3="$plugin" bash scripts/test-live-instrument.sh Tests/Apple/VST3/TimelineTransportTests.swift
