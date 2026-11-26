#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Runs the real prepared-source graph without opening a hardware output.
# Reports 200-voice render cost and checks live FX edits sample by sample.
bash scripts/test-audio.sh Tests/Apple/PreparedItemGraphPerformanceTests.swift
