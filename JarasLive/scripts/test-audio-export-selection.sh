#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-export-selection.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swiftc -swift-version 5 -parse-as-library Apple/Shared/AudioExportSelection.swift Tests/Apple/AudioExportSelectionTests.swift -o "$test_dir/test"
"$test_dir/test"
