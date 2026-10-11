#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-remote-sidebar.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
out = Path(sys.argv[1])
source = Path('Apple/Shared/DAWRemoteView.swift').read_text()
start = source.index('private enum RemoteSidebarMetrics {')
end = source.index('@MainActor private struct NativeRemoteWorkspace:', start)
rail = source[start:end]
# Both roles on both devices must use the same fixed-size, scrollable rail.
assert source.count('RemoteSidebarRail(hidden: sidebarHidden) {') == 4
fixture = Path('Tests/Apple/DAWRemoteSidebarLayoutTests.swift').read_text()
out.joinpath('main.swift').write_text('import SwiftUI\n' + rail + fixture)
out.joinpath('iOS.swift').write_text('import SwiftUI\nprivate enum RemoteSurface { static let panel = Color.gray }\n' + rail)
PY
swiftc -typecheck -swift-version 5 -target arm64-apple-ios16.0 -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" "$test_dir/iOS.swift"
swiftc -O -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
