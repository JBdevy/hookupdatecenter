#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export JARAS_AUDIO_TEST_SOURCE=Tests/Apple/PlaybackSampleEpochTests.swift
exec bash scripts/test-audio.sh
