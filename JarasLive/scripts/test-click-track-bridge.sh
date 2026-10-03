#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-click-bridge.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
clang++ -std=c++17 -fobjc-arc -c Apple/Bridge/JarasCoreBridge.mm -o "$test_dir/bridge.o"
clang++ -std=c++17 -c Core/Project/Models.cpp -o "$test_dir/models.o"
clang++ -std=c++17 -c Core/Transport/Engine.cpp -o "$test_dir/engine.o"
clang++ -std=c++17 -c Core/Import/TrackTaxonomy.cpp -o "$test_dir/taxonomy.o"
cp Tests/Apple/ClickTrackBridgeTests.swift "$test_dir/main.swift"
swiftc -swift-version 5 -import-objc-header Apple/Bridge/JarasCoreBridge.h \
 Application/Project/OutputPatch.swift Application/Project/NativeFXSettings.swift Application/Project/TrackRouting.swift \
 Application/Project/MultiLoop.swift Application/Project/ProjectModels.swift Application/Project/MIDIItem.swift Application/Project/TimelineTempo.swift \
 "$test_dir/main.swift" "$test_dir"/*.o -lc++ -o "$test_dir/test"
"$test_dir/test"
