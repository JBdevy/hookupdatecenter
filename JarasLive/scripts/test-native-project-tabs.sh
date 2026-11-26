#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-native-tabs.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
python3 - "$build_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source=Path('Apple/Shared/IpadNativeHome.swift').read_text()
start=source.index('@MainActor final class NativeProjectTabs')
end=source.index('@MainActor private struct NativeProjectTabBar',start)
fixture=Path('Tests/Apple/NativeProjectTabsTests.swift').read_text()
Path(sys.argv[1]).write_text(fixture.replace('// INSERT_NATIVE_PROJECT_TABS',source[start:end]))
PY
swiftc -swift-version 5 -parse-as-library "$build_dir/main.swift" -o "$build_dir/test"
"$build_dir/test"
