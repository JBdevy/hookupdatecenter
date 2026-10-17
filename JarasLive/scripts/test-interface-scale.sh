#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-interface-scale.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
cp Tests/Apple/InterfaceScalingTests.swift "$build_dir/main.swift"
swiftc -parse-as-library Application/Project/InterfaceScale.swift Apple/Shared/InterfaceScaling.swift "$build_dir/main.swift" -o "$build_dir/test"
"$build_dir/test"
