#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
capacity_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-playback-capacity.XXXXXX")"
trap 'rm -rf "$capacity_test_dir"' EXIT
clang++ -O2 -std=c++17 Tests/Core/PlaybackCapacityTests.cpp Core/Project/Models.cpp Core/Transport/Engine.cpp Core/Import/TrackTaxonomy.cpp -o "$capacity_test_dir/test"
"$capacity_test_dir/test"
