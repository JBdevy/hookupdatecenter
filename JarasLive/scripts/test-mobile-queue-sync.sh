#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
JARAS_PREPARED_TEST_SOURCE=Tests/Apple/MobilePreparedSyncTests.swift bash scripts/test-prepared-clip-audio.sh
JARAS_AUDIO_TEST_SOURCE=Tests/Apple/MobileQueueSyncTests.swift bash scripts/test-audio.sh
