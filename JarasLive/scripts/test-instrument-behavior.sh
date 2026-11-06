#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-instrument-behavior.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
font="${1:-${JARAS_TEST_SF2:-}}"
if [[ -z "$font" ]]; then
    font="$build_dir/test-tone.sf2"
    python3 scripts/generate-test-sf2.py "$font"
fi
clang++ -O2 -std=c++17 -mmacosx-version-min=12.0 -fobjc-arc -framework AVFoundation -framework Foundation Tests/Apple/InstrumentBehaviorTests.mm -o "$build_dir/test"
"$build_dir/test" "$font"
