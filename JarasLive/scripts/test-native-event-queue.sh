#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-input-queue.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
cp Tests/Apple/NativeTimelineEventQueueTests.swift "$test_dir/main.swift"
swiftc -swift-version 5 Apple/Shared/NativeTimelineInputGate.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
