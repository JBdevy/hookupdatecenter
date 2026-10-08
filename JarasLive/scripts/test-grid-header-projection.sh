#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -e /tmp/catlive-perf-measurement.lock ]]; then
  echo "Performance measurement is active; header projection test deferred." >&2
  exit 2
fi
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-header-projection.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
out = Path(sys.argv[1])
source = Path('Apple/Shared/GridSelectionInput.swift').read_text()
source = source.replace('private func invalidateHeaderProjectionIfNeeded()', 'private func invalidateHeaderProjectionImplementation()')
needle = '    @discardableResult private func invalidateHeaderProjectionImplementation()'
wrapper = '''    @discardableResult func invalidateHeaderProjectionIfNeeded() -> Bool {
        let changed = invalidateHeaderProjectionImplementation()
        if changed { HeaderProjectionProbe.invalidations += 1 }
        return changed
    }
'''
source = source.replace(needle, wrapper + needle)
(out / 'GridSelectionInput.swift').write_text(source)
(out / 'main.swift').write_text(Path('Tests/Apple/GridHeaderProjectionTests.swift').read_text())
PY
swiftc -swift-version 5 -target "$(uname -m)-apple-macos12.0" Apple/Shared/NativeTooltips.swift Apple/Shared/NativeTimelineInputGate.swift "$test_dir/GridSelectionInput.swift" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
