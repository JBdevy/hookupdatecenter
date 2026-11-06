#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-grid-ink.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
printf 'import Foundation\n@main struct GridInkTests { @MainActor static func main() { verifyTimelineGridInk() } }\n' > "$test_dir/main.swift"
swiftc -parse-as-library -swift-version 5 Apple/Shared/TimelineGridInk.swift Tests/Apple/TimelineGridInkTests.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
xcrun swiftc -typecheck -swift-version 5 -target arm64-apple-ios16.0 -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" \
    Apple/Shared/TimelineGridInk.swift Tests/Apple/TimelineGridInkTests.swift
