#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import pathlib, subprocess, tempfile
source = pathlib.Path('Apple/Shared/IpadItemActions.swift').read_text()
start = source.index('@MainActor private final class IpadItemProcessingSession:')
end = source.index('@MainActor private struct IpadItemExportEditor:',start)
coordinator = source[start:end].replace('@MainActor private final class', '@MainActor final class',1)
fixture = pathlib.Path('Tests/Apple/IpadItemProcessingTests.swift').read_text().replace('// PRODUCTION_COORDINATOR',coordinator)
with tempfile.TemporaryDirectory(prefix='catlive-ipad-item-processing-') as directory:
    output = pathlib.Path(directory)
    (output/'Tests.swift').write_text(fixture)
    subprocess.run(['swiftc','-swift-version','5','-parse-as-library',str(output/'Tests.swift'),'-o',str(output/'Tests')],check=True)
    subprocess.run([str(output/'Tests')],check=True)
PY
