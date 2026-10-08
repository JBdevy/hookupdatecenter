#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -e /tmp/catlive-perf-measurement.lock ]]; then
  echo "Performance measurement is active; index compilation deferred." >&2
  exit 2
fi
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-visible-clip-index.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swiftc -O -swift-version 5 Apple/Shared/TimelineVisibleClipIndex.swift \
  Tests/Apple/TimelineVisibleClipIndexTests.swift -o "$test_dir/test"
"$test_dir/test"
