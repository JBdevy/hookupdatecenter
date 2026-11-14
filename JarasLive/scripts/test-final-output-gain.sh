#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-final-output-gain.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
CATLIVE_EXPORT_TEST_SOURCE=Tests/Apple/FinalOutputGainTests.swift \
CATLIVE_EXPORT_TEST_BINARY="$build_dir/test" CATLIVE_EXPORT_TEST_BUILD_ONLY=1 bash scripts/test-offline-export.sh
"$build_dir/test" "$@"

if [[ "$*" != *--manual-only* && "$*" != *--unavailable-output* ]]; then "$build_dir/test" --unavailable-output; fi
