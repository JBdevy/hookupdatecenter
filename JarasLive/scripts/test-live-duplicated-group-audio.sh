#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Requires a real Core Audio output; all physical output is muted by the fixture.
bash scripts/test-audio.sh Tests/Apple/LiveDuplicatedGroupAudioTests.swift
