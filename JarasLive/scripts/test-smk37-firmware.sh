#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-smk-firmware.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
cp Tests/Apple/SMK37FirmwareTests.swift "$test_dir/main.swift"
swiftc -swift-version 5 Application/Controls/SMK37FirmwareBackup.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test" "$PWD/Resources/SMK37" "$@"
