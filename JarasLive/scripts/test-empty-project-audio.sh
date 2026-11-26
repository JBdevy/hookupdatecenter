#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CATLIVE_EXPORT_TEST_SOURCE=Tests/Apple/EmptyProjectAudioTests.swift bash scripts/test-offline-export.sh
