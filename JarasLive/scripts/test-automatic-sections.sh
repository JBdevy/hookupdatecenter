#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-automatic-sections.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
clang++ -std=c++17 Tests/Core/AutomaticSectionTests.cpp Core/Transport/Engine.cpp Core/Project/Models.cpp -o "$build_dir/test"
"$build_dir/test"
