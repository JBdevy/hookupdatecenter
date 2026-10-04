#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-external-preview.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
cp Tests/Apple/GridExternalMediaPreviewTests.swift "$test_dir/main.swift"
swiftc -swift-version 5 Apple/Shared/GridInsertionPreview.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
