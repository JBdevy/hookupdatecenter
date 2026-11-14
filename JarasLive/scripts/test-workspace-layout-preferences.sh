#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-layout-preferences.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swiftc -parse-as-library Application/Project/InterfaceScale.swift Tests/Apple/WorkspaceLayoutPreferencesTests.swift -o "$test_dir/test"
"$test_dir/test"
