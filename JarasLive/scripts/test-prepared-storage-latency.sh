#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
JARAS_PREPARED_TEST_SOURCE=Tests/Apple/PreparedStorageLatencyTests.swift bash scripts/test-prepared-clip-audio.sh
