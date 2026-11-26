#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --jobs 2 > /dev/null
module_dir="$(swift build --show-bin-path)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-paste-documents.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/ProjectDocuments.swift').read_text()
start = source.index('    func pasteGridItems(')
paste = source[start:source.index('    func pasteMedia(', start)]
start = source.index('@MainActor final class GridMediaClipboard')
clipboard = source[start:source.index('\n#endif', start)]
# Keep the production pasteboard logic, isolated from the user's clipboard.
clipboard = clipboard.replace('static let shared = GridMediaClipboard()', 'static let shared = GridMediaClipboard(pasteboard: NSPasteboard.withUniqueName())')
fixture = Path('Tests/Apple/CrossProjectPasteTests.swift').read_text()
Path(sys.argv[1]).write_text(fixture.replace('// INSERT_DOCUMENT_PASTE', paste).replace('// INSERT_MEDIA_CLIPBOARD', clipboard))
PY
python3 - "$module_dir" "$test_dir" <<'PY'
from pathlib import Path
import subprocess, sys
build, fixture = map(Path, sys.argv[1:])
module = build / 'Modules' if (build / 'Modules').is_dir() else build
archive = build / 'libJarasApplication.a'
objects = [archive] if archive.exists() else list((build / 'JarasApplication.build').glob('*.o'))
if not objects:
    raise SystemExit('Application build objects are missing')
subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-I', str(module),
                str(fixture / 'main.swift'), *map(str, objects), '-o', str(fixture / 'test')], check=True)
PY
"$test_dir/test" "$@"
