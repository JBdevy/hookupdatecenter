#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d "${TMPDIR:-/tmp}/catlive-timing-history.XXXXXX")"
trap 'rm -rf "$out"' EXIT
clang++ -std=c++17 -O2 Core/Project/Models.cpp Core/Transport/Engine.cpp Core/Import/TrackTaxonomy.cpp Tests/Core/TimingHistoryTests.cpp -o "$out/test"
"$out/test"
