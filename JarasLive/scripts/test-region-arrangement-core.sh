#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-region-arrangement.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
for source in Core/Project/Models.cpp Core/Transport/Engine.cpp Core/Import/TrackTaxonomy.cpp; do
  c++ -std=c++17 -O1 -Wall -Wextra -Wno-missing-field-initializers -I Core \
    -c "$source" -o "$test_dir/$(basename "$source" .cpp).o"
done
for suite in RegionArrangement RegionMovementCoverage RegionOnsetOwnership RegionBoundaryOwnership ItemRateAndLoop; do
  c++ -std=c++17 -O1 -Wall -Wextra -Wno-missing-field-initializers -I Core \
    "$test_dir/Models.o" "$test_dir/Engine.o" "$test_dir/TrackTaxonomy.o" \
    "Tests/Core/${suite}Tests.cpp" -o "$test_dir/test"
  "$test_dir/test"
done
