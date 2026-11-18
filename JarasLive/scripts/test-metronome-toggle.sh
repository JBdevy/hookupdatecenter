#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-metronome-toggle.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys, uuid
source = Path('Apple/Shared/StemAudioPlayback.swift').read_text()
start = source.index('private enum MetronomePreferences {')
end = source.index('@MainActor final class TrackMIDIActivity:', start)
stubs = '''import AVFoundation
import Combine
enum ProjectError: Error { case invalid(String) }
struct MetronomeSoundRequest { let preset: String; let pathA: String; let pathB: String; let sampleRate: Double }
enum AudioFileRead {
    static func prepare<Value: Sendable>(_ work: @escaping @Sendable (@escaping @Sendable () -> Bool) throws -> Value) async throws -> Value {
        try await Task.detached { try work({ false }) }.value
    }
}
'''
settings = source[start:end].replace('com.hookdeveloper.catlive.metronome', 'catlive.test.metronome.' + uuid.uuid4().hex)
Path(sys.argv[1]).write_text(stubs + settings + Path('Tests/Apple/MetronomeToggleTests.swift').read_text())
PY
swiftc -swift-version 5 Application/Project/OutputPatch.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"