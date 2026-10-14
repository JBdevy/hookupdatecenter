#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
picker_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-native-package-picker.XXXXXX")"
trap 'rm -rf "$picker_test_dir"' EXIT
python3 - "$picker_test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
home = Path('Apple/Shared/IpadNativeHome.swift').read_text()
begin = home.index('    final class Coordinator: NSObject, UIDocumentPickerDelegate')
coordinator = home[begin:home.index('\n}\n', begin)]
source = Path('Apple/Shared/ProjectDocuments.swift').read_text()
def method(signature):
    begin = source.index(signature)
    body = source[begin:source.index('\n    }', begin) + 6]
    if '#if os(macOS)' in body:
        start = body.index('        #if os(macOS)')
        alternate = body.index('        #else', start)
        end = body.index('        #endif', alternate)
        body = body[:start] + body[alternate + len('        #else\n'):end] + body[end + len('        #endif\n'):]
    return body
methods = '\n'.join(method(name) for name in [
    '    func continueNativePackageImport(', '    func cancelNativePackageImport(',
    '    func importPortablePackage(_ url: URL)', '    func browsePortablePackage()'])
fixture = Path('Tests/Apple/NativePackagePickerTests.swift').read_text()
Path(sys.argv[1]).write_text(fixture.replace('// PRODUCTION_COORDINATOR', coordinator).replace('// PRODUCTION_PACKAGE_METHODS', methods))
PY
swiftc -swift-version 5 "$picker_test_dir/main.swift" -o "$picker_test_dir/test"
"$picker_test_dir/test"
