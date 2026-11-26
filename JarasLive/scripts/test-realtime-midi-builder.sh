#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
midi_builder_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-midi-builder.XXXXXX")"
trap 'rm -rf "$midi_builder_test_dir"' EXIT
"${CXX:-clang++}" -std=c++17 -O2 -Wall -Wextra -Werror -pedantic \
    Tests/Core/BoundedMIDIBuilderTests.cpp -o "$midi_builder_test_dir/test"
"$midi_builder_test_dir/test"
