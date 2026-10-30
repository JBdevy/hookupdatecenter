#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
queue_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-realtime-midi.XXXXXX")"
trap 'rm -rf "$queue_test_dir"' EXIT
"${CXX:-clang++}" -std=c++17 -O2 -pthread Tests/Core/RealtimeMIDIQueueTests.cpp -o "$queue_test_dir/test"
"$queue_test_dir/test"
