#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-project-transition.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" "${CATLIVE_PROJECT_DOCUMENTS_TEST_SOURCE:-Apple/Shared/ProjectDocuments.swift}" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[2]).read_text()
opening = source[source.index('    func open(_ url: URL) {'):source.index('        beginOpening {', source.index('    func open(_ url: URL) {'))]
# Check the real admission guards without opening the user's files.
opening += '        openingRequests += 1\n    }\n'
start = source.index('    private func finish(scan:')
finish = source[start:source.index('                let result = try await Task.detached', start)]
# Stop at the real import-worker boundary; capture precisely the value the
# production importer receives, after its normal save/preset-capture phase.
finish += '''                _ = remove
                capturedBase = base
            } catch { self.error = error.localizedDescription }
        }
    }
'''
fixture = Path('Tests/Apple/ProjectTransitionStabilityTests.swift').read_text()
Path(sys.argv[1]).write_text(fixture.replace('    // INSERT_TRANSITION_METHODS', opening + finish))
PY
swiftc -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
