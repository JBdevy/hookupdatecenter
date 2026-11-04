#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
clock_test="$(mktemp "${TMPDIR:-/tmp}/catlive-mobile-clock.XXXXXX")"
trap 'rm -f "$clock_test"' EXIT
clang++ -std=c++17 Tests/Apple/MobileRenderClockTests.cpp -o "$clock_test"
"$clock_test"
JARAS_PREPARED_TEST_SOURCE=Tests/Apple/MobilePreparedSyncTests.swift bash scripts/test-prepared-clip-audio.sh
JARAS_AUDIO_TEST_SOURCE=Tests/Apple/MobileQueueSyncTests.swift bash scripts/test-audio.sh
