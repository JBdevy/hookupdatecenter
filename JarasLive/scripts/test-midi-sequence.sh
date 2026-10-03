#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-midi-sequence.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
clang++ -std=c++17 -O2 -pthread Tests/Apple/MIDISequenceTests.cpp -o "$build_dir/test"
"$build_dir/test"
