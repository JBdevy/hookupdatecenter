#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-rapid-tempo.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
CATLIVE_EXPORT_TEST_SOURCE=Tests/Apple/RapidTempoStressTests.swift \
CATLIVE_EXPORT_TEST_BINARY="$test_dir/test" CATLIVE_EXPORT_TEST_BUILD_ONLY=1 \
CATLIVE_EXPORT_TEST_OPTIMIZED=1 bash scripts/test-offline-export.sh
# Uses the selected hardware; the physical output is muted by the fixture.
CATLIVE_TEST_VOICES="${CATLIVE_TEST_VOICES:-200}" \
CATLIVE_BUFFERED_MAC_AUDIO="${CATLIVE_BUFFERED_MAC_AUDIO:-1}" "$test_dir/test"
