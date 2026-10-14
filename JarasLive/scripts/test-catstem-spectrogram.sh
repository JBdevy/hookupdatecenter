#!/bin/bash
set -euo pipefail
CATSTEM_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CATSTEM_BUILD="${TMPDIR:-/tmp}/catlive-catstem-spectrogram"
CATSTEM_PYTHON="${CATSTEM_TEST_PYTHON:-$CATSTEM_ROOT/build/StemSeparationRuntime/arm64/python/bin/python3.11}"
mkdir -p "$CATSTEM_BUILD"
"$CATSTEM_PYTHON" "$CATSTEM_ROOT/scripts/catstem/spectral-fixtures.py" "$CATSTEM_BUILD"
xcrun clang++ -std=c++17 -O2 -framework Accelerate \
    "$CATSTEM_ROOT/Tests/Apple/CatStemSpectrogramTests.cpp" -o "$CATSTEM_BUILD/test-spectrogram"
"$CATSTEM_BUILD/test-spectrogram" "$CATSTEM_BUILD"
