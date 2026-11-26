#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-backup-opening.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swift build --product JarasApplication --jobs 2 >/dev/null
products="$(swift build --show-bin-path)"
swiftc -O -swift-version 5 -I "$products" -L "$products" -lJarasApplication Tests/Apple/ProjectBackupOpeningProgressTests.swift -o "$test_dir/test"
"$test_dir/test"
