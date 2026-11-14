#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
preparation_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-play-preparation.XXXXXX")"
trap 'rm -rf "$preparation_test_dir"' EXIT
clang++ -std=c++17 -fobjc-arc -c Apple/Bridge/JarasCoreBridge.mm -o "$preparation_test_dir/bridge.o"
clang++ -std=c++17 -c Core/Project/Models.cpp -o "$preparation_test_dir/models.o"
clang++ -std=c++17 -c Core/Transport/Engine.cpp -o "$preparation_test_dir/engine.o"
clang++ -std=c++17 -c Core/Import/TrackTaxonomy.cpp -o "$preparation_test_dir/taxonomy.o"
preparation_sources=()
while IFS= read -r source; do preparation_sources+=("$source"); done < <(rg --files Application -g '*.swift')
swiftc -swift-version 5 -parse-as-library -import-objc-header Apple/Bridge/JarasCoreBridge.h \
    "${preparation_sources[@]}" Apple/Bridge/LocalCommandExecutor.swift \
    Tests/Apple/PlaybackPreparationTests.swift "$preparation_test_dir"/*.o -lc++ -o "$preparation_test_dir/test"
"$preparation_test_dir/test"
