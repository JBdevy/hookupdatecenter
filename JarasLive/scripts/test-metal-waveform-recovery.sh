#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -e /tmp/catlive-perf-measurement.lock ]]; then
  echo "Performance measurement is active; Metal recovery tests deferred." >&2
  exit 2
fi
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-metal-recovery.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
output = Path(sys.argv[1])
source = Path('Apple/Shared/MetalWaveformRenderer.swift').read_text()
target = 'guard let drawable = currentDrawable else { retryDrawableOnce(); return }'
assert source.count(target) == 1
source = source.replace(target, 'guard let drawable = MetalDrawableRecoveryProbe.acquire(self) else { retryDrawableOnce(); return }')
source += '''
// Test-only acquisition failure: no production hooks or polling are needed.
enum MetalDrawableRecoveryProbe {
    static var blocked = false
    static var attempts = 0
    static func acquire(_ view: MTKView) -> CAMetalDrawable? {
        attempts += 1
        return blocked ? nil : view.currentDrawable
    }
}
extension MetalWaveformSurface {
    var pendingForRecoveryTest: Bool { renderer.pendingForRecoveryTest }
    func invalidateDrawableForRecoveryTest() {
        renderer.releaseDrawables()
        renderer.needsDisplay = true
        renderer.displayIfNeeded()
    }
    var presentedForRecoveryTest: MetalWaveformFrame? { presented }
}
extension MetalWaveformRenderView {
    var pendingForRecoveryTest: Bool { pending != nil }
}
'''
(output / 'MetalWaveformRenderer.swift').write_text(source)
(output / 'main.swift').write_text(Path('Tests/Apple/MetalWaveformRecoveryTests.swift').read_text())
PY
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos12.0" \
  Apple/Shared/TimelineRenderDiagnostics.swift Application/Project/AudioFileRead.swift \
  Apple/Shared/TimelineAudioWaveform.swift "$test_dir/MetalWaveformRenderer.swift" \
  "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
