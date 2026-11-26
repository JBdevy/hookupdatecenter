#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-fx-history.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/ExternalPluginEditor.swift').read_text()
start = source.index('@MainActor enum FXHistoryShortcut')
end = source.index('@MainActor private final class FXChainTableView', start)
Path(sys.argv[1]).write_text('import AppKit\n' + source[start:end] + Path('Tests/Apple/FXHistoryShortcutTests.swift').read_text())
PY
swiftc -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
