#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catstem-realtime.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
clang++ -std=c++17 -O2 -fobjc-arc -mmacosx-version-min=12.0 Tests/Apple/CatStemRealtimeTests.mm -framework AVFoundation -framework AudioToolbox -framework Foundation -o "$build_dir/test"
"$build_dir/test" "$(command -v python3)" "$PWD/Tests/Apple/CatStemIdentityWorker.py"
