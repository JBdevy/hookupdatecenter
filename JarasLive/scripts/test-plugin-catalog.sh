#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-plugin-catalog.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
python3 - "$build_dir/main.swift" <<'PY'
from pathlib import Path
import sys
catalog=Path('Apple/Shared/PluginCatalog.swift').read_text()
model=Path('Application/Project/NativeFXSettings.swift').read_text()
parts=['import AppKit\nimport Combine\nimport CryptoKit\nimport Darwin\n', 'enum JarasLocalization { static func string(_ s: String) -> String { s } }']
parts.append(model[model.index('public struct ExternalPlugin:'):model.index('public struct NativeFXInstance:')])
parts.append(catalog[catalog.index('struct RecognizedPlugin:'):catalog.index('/// One import owns this session')])
parts.append(Path('Tests/Apple/VST3/CatalogTests.swift').read_text())
Path(sys.argv[1]).write_text('\n'.join(parts))
PY
swiftc -swift-version 5 "$build_dir/main.swift" -o "$build_dir/test"
"$build_dir/test"
