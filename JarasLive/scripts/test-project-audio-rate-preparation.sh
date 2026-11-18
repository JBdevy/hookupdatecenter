#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/test-audio.sh Tests/Apple/ProjectAudioRatePreparationTests.swift
