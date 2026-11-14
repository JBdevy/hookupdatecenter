#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
geometry_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-row-geometry.XXXXXX")"
trap 'rm -rf "$geometry_test_dir"' EXIT
clang++ -std=c++17 -O2 -fsanitize=address,undefined Tests/Core/WindowsTrackRowGeometryTests.cpp -o "$geometry_test_dir/test"
"$geometry_test_dir/test"
