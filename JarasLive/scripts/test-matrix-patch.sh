#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-matrix.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
"${CXX:-clang++}" -std=c++17 -Wall -Wextra -pedantic Tests/Core/MatrixPatchTests.cpp Core/Project/Models.cpp -o "$test_dir/test"
"$test_dir/test"
