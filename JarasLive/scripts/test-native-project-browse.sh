#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
browse_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-project-browse.XXXXXX")"
trap 'rm -rf "$browse_test_dir"' EXIT
python3 - "$browse_test_dir/main.swift" <<'CODE'
from pathlib import Path
import sys
source=Path('Apple/Shared/ProjectDocuments.swift').read_text()
def method(name):
 a=source.index(name);body=source[a:source.index('\n    }',a)+6]
 if '#if os(macOS)' in body:
  a=body.index('        #if os(macOS)');b=body.index('        #else',a);c=body.index('        #endif',b)
  body=body[:a]+body[b+len('        #else\n'):c]+body[c+len('        #endif\n'):]
 return body.replace('private func cancelNativeProjectOpen','func cancelNativeProjectOpen')
methods='\n'.join(method(x) for x in ['    func browse()', '    private func receiveNativeProject(', '    private func cancelNativeProjectOpen()'])
Path(sys.argv[1]).write_text(Path('Tests/Apple/NativeProjectBrowseTests.swift').read_text().replace('// PRODUCTION_METHODS',methods))
CODE
swiftc -swift-version 5 -parse-as-library "$browse_test_dir/main.swift" -o "$browse_test_dir/test"
"$browse_test_dir/test"
