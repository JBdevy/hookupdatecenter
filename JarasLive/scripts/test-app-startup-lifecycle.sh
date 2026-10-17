#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-startup-lifecycle.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
python3 - "$build_dir/Fixture.swift" <<'PYTHON'
from pathlib import Path
import sys
src=Path('Apple/Shared/AppContainer.swift').read_text()
helper=src[src.index('enum AppStartupPresentation'):src.index('@MainActor final class AppContainer')]
methods=src[src.index('    func start() async {'):src.rfind('\n}')]
stubs='''import Foundation
@MainActor final class FakeAuth {
 var restores = 0, expiryChecks = 0
 func restore() async { restores += 1; try? await Task.sleep(nanoseconds: 60_000_000) }
 func checkLocalExpiry() { expiryChecks += 1 }
 func checkOnlineAccess() async {}
}
final class Connectivity {
 struct Path { enum Status { case satisfied }; var status: Status = .satisfied }
 var pathUpdateHandler: ((Path) -> Void)?
 var starts = 0
 func start(queue: DispatchQueue) { starts += 1 }
}
@MainActor enum DAWRemoteHostBridge { static func bind(_ show: Int) {} }
@MainActor final class DAWRemoteSession {
 static let shared = DAWRemoteSession()
 func restoreHostPreference() {}
}
'''
fixture='''@MainActor final class AppContainerFixture {
 var preview = false, starting = true
 var startupProgress = 0.1, startupStage = ""
 private var startupTask: Task<Void, Never>?
 let auth = FakeAuth(), accessConnectivity = Connectivity(), show = 0
'''+methods+'\n}\n'
Path(sys.argv[1]).write_text(stubs+helper+fixture)
PYTHON
swiftc -parse-as-library "$build_dir/Fixture.swift" Tests/Apple/AppStartupLifecycleTests.swift -o "$build_dir/test"
"$build_dir/test"
