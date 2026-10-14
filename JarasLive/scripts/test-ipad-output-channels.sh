#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-ipad-output.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
folder = Path(sys.argv[1])
source = Path('Apple/Shared/AudioDeviceSettings.swift').read_text()
stubs = '''
enum JarasLocalization { static func string(_ key: String) -> String { key } }
enum ProjectError: Error { case invalid(String) }
'''
folder.joinpath('iOS.swift').write_text(source + stubs)
start = source.index('    private func configureMobileOutputChannels(')
method = source[start:source.index('    func requireLocalInput(', start)]
folder.joinpath('main.swift').write_text('import Foundation\n' + '''
final class AVAudioSession {
 var maximumOutputNumberOfChannels = 8
 var outputNumberOfChannels = 2
 var preferredOutputNumberOfChannels = 2
 var requests: [Int] = []
 var reject = false
 func setPreferredOutputNumberOfChannels(_ count: Int) throws {
  requests.append(count)
  if reject { throw NSError(domain: "Device rejected channels", code: 1) }
  preferredOutputNumberOfChannels = count
  outputNumberOfChannels = count
 }
}
struct Probe {
 func configure(_ session: AVAudioSession) throws { try configureMobileOutputChannels(session) }
''' + method + '''
}
let probe = Probe(), session = AVAudioSession()
try probe.configure(session)
precondition(session.requests == [8] && session.outputNumberOfChannels == 8)
try probe.configure(session)
precondition(session.requests == [8], "Do not reconfigure an already negotiated route")
session.maximumOutputNumberOfChannels = 6; session.outputNumberOfChannels = 2
try probe.configure(session)
precondition(session.requests == [8, 6] && session.outputNumberOfChannels == 6)
session.outputNumberOfChannels = 2
try probe.configure(session)
precondition(session.requests == [8, 6], "A pending preference must not cause a notification loop")
session.maximumOutputNumberOfChannels = 0
try probe.configure(session)
precondition(session.requests == [8, 6], "Disconnected routes must not request zero channels")
session.maximumOutputNumberOfChannels = 4; session.reject = true
do { try probe.configure(session); fatalError("Device errors must propagate") }
catch { precondition(session.outputNumberOfChannels == 2, "Do not pretend rejected channels exist") }
print("IPAD_OUTPUT_CHANNEL_NEGOTIATION_ROUTE_CHANGES_NO_NOTIFICATION_LOOP_AND_ERRORS_OK")
''')
PY
swiftc -typecheck -swift-version 5 -target arm64-apple-ios16.0 -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" "$test_dir/iOS.swift"
swiftc -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
