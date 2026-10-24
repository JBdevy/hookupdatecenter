#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-picker-handoff.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
python3 - "$build_dir/main.swift" <<'PY'
from pathlib import Path
import sys
s=Path('Apple/Shared/IpadNativeHome.swift').read_text()
a=s.index('@MainActor private final class NativeProjectPickerHandoff:')
b=s.index('struct NativeProjectPresentation:',a)
f=Path('Tests/Apple/NativeProjectPickerHandoffTests.swift').read_text()
Path(sys.argv[1]).write_text(f.replace('// PRODUCTION_HANDOFF',s[a:b]))
PY
swiftc -swift-version 5 -parse-as-library "$build_dir/main.swift" -o "$build_dir/test"
"$build_dir/test"
