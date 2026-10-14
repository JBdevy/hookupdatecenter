#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export JARAS_TEST_PYTHON="$(command -v python3)"
export JARAS_AUDIO_TEST_SOURCE=Tests/Apple/CatStemProjectCloseTests.swift
exec bash scripts/test-audio.sh
