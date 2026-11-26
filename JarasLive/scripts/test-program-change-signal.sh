#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d "${TMPDIR:-/tmp}/catlive-program-signal.XXXXXX")"
trap 'rm -rf "$out"' EXIT
clang++ -std=c++17 -fobjc-arc Apple/Bridge/JarasTimecode.mm Tests/Apple/ProgramChangeSignalTests.mm -framework Foundation -framework AVFoundation -framework CoreMIDI -o "$out/test"
"$out/test"
