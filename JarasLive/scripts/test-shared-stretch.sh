#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-shared-stretch.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
clang++ -std=c++17 -O1 -fsanitize=address,undefined Tests/Core/SharedRenderPoolTests.cpp -o "$test_dir/pool"
"$test_dir/pool"
JARAS_PREPARED_TEST_SOURCE=Tests/Apple/SharedStretchAudioTests.swift bash scripts/test-prepared-clip-audio.sh
