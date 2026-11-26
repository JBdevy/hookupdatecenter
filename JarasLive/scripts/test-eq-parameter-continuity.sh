#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-eq-continuity.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT
clang++ -O3 -std=c++17 -fobjc-arc -c Apple/Bridge/JarasEffects.mm -o "$fixture_dir/effects.o"
swiftc -swift-version 5 -default-isolation MainActor -import-objc-header Apple/Bridge/JarasEffects.h \
 -I .build/out/Products/Debug -L .build/out/Products/Debug -lJarasApplication Tests/Apple/EQParameterContinuityTests.swift \
 "$fixture_dir/effects.o" -framework Accelerate -lc++ -o "$fixture_dir/test"
"$fixture_dir/test" "$@"
