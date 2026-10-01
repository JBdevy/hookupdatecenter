#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-remote.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
cat Application/Project/TeleprompterSettings.swift Apple/Shared/DAWRemoteProtocol.swift Apple/Shared/DAWRemoteSession.swift Tests/Apple/DAWRemoteTests.swift Tests/Apple/DAWRemoteTeleprompterTests.swift > "$test_dir/main.swift"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
