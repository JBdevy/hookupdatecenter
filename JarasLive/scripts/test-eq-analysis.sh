#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
result_dir=$(mktemp -d /private/tmp/catlive-eq-analysis.XXXXXX)
trap 'rm -rf "$result_dir"' EXIT
"${CXX:-clang++}" -std=c++17 -O2 -pthread -I Core Tests/Core/EQAnalysisTests.cpp -o "$result_dir/eq-analysis"
"$result_dir/eq-analysis"
