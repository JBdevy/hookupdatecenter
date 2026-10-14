#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-region-boundary-ownership.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
c++ -std=c++17 -Wall -Wextra -Wno-missing-field-initializers -ICore/Project "${MODELS_SOURCE:-Core/Project/Models.cpp}" Core/Transport/Engine.cpp Core/Import/TrackTaxonomy.cpp Tests/Core/RegionBoundaryOwnershipTests.cpp -o "$build_dir/test"
"$build_dir/test"
