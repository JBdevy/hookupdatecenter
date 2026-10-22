#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-native-stems.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/ProjectDocuments.swift').read_text()
methods = source[source.index('    func confirmNativeStemImport('):source.index('    func cancelNativeProjectName()')]
fixture = Path('Tests/Apple/NativeStemConfirmationTests.swift').read_text()
assert fixture.count('// PRODUCTION_CONFIRMATION_METHODS') == 1
policy = Path('Application/Project/ProjectDocumentCodec.swift').read_text()
policy = policy[policy.index('public enum ProjectDirectoryPolicy {'):policy.index('/// Portable application document protection')]
Path(sys.argv[1]).write_text(fixture.replace('// PRODUCTION_CONFIRMATION_METHODS', methods).replace('// PRODUCTION_DIRECTORY_POLICY', policy))
PY
swiftc -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
