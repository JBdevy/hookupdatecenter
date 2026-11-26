#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d "${TMPDIR:-/tmp}/catlive-waveform-detail.XXXXXX")"
trap 'rm -rf "$out"' EXIT
clang++ -std=c++17 -O2 -Wall -Wextra -pedantic Tests/Core/WaveformDetailPeaksTests.cpp -o "$out/test"
"$out/test"
