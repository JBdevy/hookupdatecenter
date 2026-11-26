#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-meter-repaint.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
"${CXX:-clang++}" -std=c++17 -O2 -Wall -Wextra -pedantic Tests/Core/WindowsMeterRepaintTests.cpp -o "$test_dir/test"
"$test_dir/test"
