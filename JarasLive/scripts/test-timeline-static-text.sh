#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-static-text.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swiftc -O -swift-version 5 Apple/Shared/TimelineStaticText.swift Tests/Apple/TimelineStaticTextTests.swift -o "$test_dir/test"
"$test_dir/test"
