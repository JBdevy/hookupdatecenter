#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
shared_voice_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-shared-voices.XXXXXX")"
trap 'rm -rf "$shared_voice_dir"' EXIT
CATLIVE_EXPORT_TEST_SOURCE=Tests/Apple/SharedFileVoiceTests.swift \
CATLIVE_EXPORT_TEST_OPTIMIZED=1 CATLIVE_EXPORT_TEST_BUILD_ONLY=1 \
CATLIVE_EXPORT_TEST_BINARY="$shared_voice_dir/test" bash scripts/test-offline-export.sh
"$shared_voice_dir/test"
if [[ "${1:-}" == "--hardware" ]]; then
    # Requires a real output device. The fixture always mutes physical output.
    "$shared_voice_dir/test" --hardware
    "$shared_voice_dir/test" --hardware --cold
fi
