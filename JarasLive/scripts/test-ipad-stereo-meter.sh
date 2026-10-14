#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-ipad-meter.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/DAWRemoteView.swift').read_text()
start = source.index('private final class IpadStereoMeterLayers')
end = source.index('/// Meter samples update two layer masks', start)
Path(sys.argv[1]).write_text('import Foundation\nimport QuartzCore\n' + source[start:end] + '\n' + Path('Tests/Apple/IpadStereoMeterTests.swift').read_text())
PY
swiftc -O -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
