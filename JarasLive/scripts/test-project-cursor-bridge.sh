#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-cursor-bridge.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
clang++ -std=c++17 -fobjc-arc -c Apple/Bridge/JarasCoreBridge.mm -o "$test_dir/bridge.o"
clang++ -std=c++17 -c Core/Project/Models.cpp -o "$test_dir/models.o"
clang++ -std=c++17 -c Core/Transport/Engine.cpp -o "$test_dir/engine.o"
clang++ -std=c++17 -c Core/Import/TrackTaxonomy.cpp -o "$test_dir/taxonomy.o"
application_sources=()
while IFS= read -r source; do application_sources+=("$source"); done < <(rg --files Application -g '*.swift')
swiftc -swift-version 5 -parse-as-library -import-objc-header Apple/Bridge/JarasCoreBridge.h \
    "${application_sources[@]}" Apple/Bridge/LocalCommandExecutor.swift \
    Tests/Apple/ProjectCursorBridgeTests.swift "$test_dir"/*.o -lc++ -o "$test_dir/test"
"$test_dir/test"
