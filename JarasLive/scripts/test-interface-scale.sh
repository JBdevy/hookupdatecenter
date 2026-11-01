#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-interface-scale.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
python3 - "$build_dir/main.swift" <<'PYTEST'
from pathlib import Path
import sys
source=Path('Apple/Shared/TransportView.swift').read_text()
style=source[source.index('struct TransportButtonStyle:'):source.index('struct TransportPreview:')]
theme=Path('Apple/Shared/Theme.swift').read_text()
theme=theme[:theme.index('    static func track(')]+'}\n'+theme[theme.index('extension Color {'):]
fixture=Path('Tests/Apple/InterfaceScalingTests.swift').read_text()
Path(sys.argv[1]).write_text(theme+'\n'+style+'\n'+fixture)
PYTEST
swiftc -parse-as-library Application/Project/InterfaceScale.swift Apple/Shared/InterfaceScaling.swift "$build_dir/main.swift" -o "$build_dir/test"
"$build_dir/test"
