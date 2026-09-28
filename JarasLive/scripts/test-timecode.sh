#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-timecode.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
clang++ -std=c++17 Tests/Core/TimecodeTests.cpp Core/Transport/Engine.cpp Core/Project/Models.cpp -o "$test_dir/test"
"$test_dir/test"
