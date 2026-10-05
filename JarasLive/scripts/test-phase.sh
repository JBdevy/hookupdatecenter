#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
JARAS_AUDIO_TEST_SOURCE=Tests/Apple/AudioPhaseTests.swift bash scripts/test-audio.sh
