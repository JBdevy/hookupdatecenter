#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-presentation-playback.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
CATLIVE_EXPORT_TEST_SOURCE=Tests/Apple/AudioPresentationPlaybackTests.swift \
CATLIVE_EXPORT_TEST_BINARY="$test_dir/test" CATLIVE_EXPORT_TEST_BUILD_ONLY=1 bash scripts/test-offline-export.sh
"$test_dir/test"
"$test_dir/test" --legacy
