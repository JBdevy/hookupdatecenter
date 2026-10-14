#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_source="$(mktemp "${TMPDIR:-/tmp}/catlive-offline-integration.XXXXXX")"
trap 'rm -f "$test_source"' EXIT
python3 - "$test_source" <<'PY'
from pathlib import Path
import sys
names = [
    'OfflinePluginLatencyTests', 'OfflineTempoContextTests', 'ItemTempoRenderTests',
    'ItemAutomationExportTests', 'OfflineRegionMixTests', 'OfflineInstrumentMixTests',
]
source = 'import Foundation\nimport AVFoundation\nimport Darwin\nsetbuf(stdout, nil)\n'
for name in names:
    body = Path('Tests/Apple', name + '.swift').read_text()
    source += '\ndo {\n' + '\n'.join(line for line in body.splitlines() if not line.startswith('import ')) + '\n}\n'
Path(sys.argv[1]).write_text(source)
PY
CATLIVE_EXPORT_TEST_SOURCE="$test_source" bash scripts/test-offline-plugin-latency.sh
