#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-remote-opening.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/Tracker.swift" <<'PY'
import pathlib,sys
source=pathlib.Path('Apple/Shared/ProjectDocuments.swift').read_text()
start=source.index('    private static var remoteOpeningID:')
end=source.index('    var remoteProjectBrowser:',start)
tracker=source[start:end]
prefix='''import Foundation
@MainActor final class ProjectDocuments {
    var ready = false
    var currentURL: URL?
    var error = ""
    var missingAudioPrompt: Bool?
'''
helpers='''
    func begin(_ id: UUID, destination: URL) {
        Self.remoteOpeningID = id; Self.remoteOpeningState = "opening"; Self.remoteOpeningError = ""
        remoteOpening = (id, destination.standardizedFileURL.resolvingSymlinksInPath())
    }
    func finish() { finishRemoteOpening() }
    func restored(_ id: UUID?, destination: URL) { updateRemoteOpeningDestination(id, to: destination) }
    var result: (id: UUID?, state: String?, error: String) {
        (Self.remoteOpeningID, Self.remoteOpeningState, Self.remoteOpeningError)
    }
    var pending: Bool { remoteOpening != nil }
}
'''
pathlib.Path(sys.argv[1]).write_text(prefix+tracker+helpers)
PY
swiftc -O -swift-version 5 -parse-as-library "$test_dir/Tracker.swift" Tests/Apple/RemoteProjectOpeningTests.swift -o "$test_dir/test"
"$test_dir/test"
