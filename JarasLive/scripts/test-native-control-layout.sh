#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-control-layout.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 scripts/native-control-layout-fixture.py "$test_dir"
for language in en pt-BR; do
    mkdir -p "$test_dir/$language.lproj"
    cp "Apple/Resources/$language.lproj/Localizable.strings" "$test_dir/$language.lproj/"
done
swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos12.0" \
    Apple/Shared/RightClickRouting.swift Apple/Shared/NativeTooltips.swift \
    "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
