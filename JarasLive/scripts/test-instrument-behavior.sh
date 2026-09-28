#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${1:?Provide a local SF2 file}"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-instrument-behavior.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
clang++ -O2 -std=c++17 -fobjc-arc -framework AVFoundation -framework Foundation Tests/Apple/InstrumentBehaviorTests.mm -o "$build_dir/test"
"$build_dir/test" "$1"
