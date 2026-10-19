#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-show-mode.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PYTEST'
from pathlib import Path
import sys
source=Path('Apple/Shared/SettingsView.swift').read_text()
start=source.index('@MainActor final class MacShowMode:')
controller=source[start:source.rindex('#endif')]
Path(sys.argv[1]).write_text('import Foundation\nimport Combine\nenum JarasLocalization { static func string(_ value: String) -> String { value } }\n'+controller+'\n'+Path('Tests/Apple/ShowModeTests.swift').read_text())
PYTEST
swiftc -swift-version 5 -parse-as-library "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
