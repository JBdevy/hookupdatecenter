#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d "${TMPDIR:-/tmp}/catlive-program.XXXXXX")"
trap 'rm -rf "$out"' EXIT
clang++ -std=c++17 -O2 Tests/Core/ProgramChangeTests.cpp -o "$out/test"
"$out/test"
