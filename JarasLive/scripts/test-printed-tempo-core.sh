#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-printed-tempo.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
c++ -std=c++17 -Wall -Wextra -Wno-missing-field-initializers Tests/Core/PrintedTempoTests.cpp Core/Transport/Engine.cpp Core/Project/Models.cpp -o "$build_dir/test"
"$build_dir/test"
