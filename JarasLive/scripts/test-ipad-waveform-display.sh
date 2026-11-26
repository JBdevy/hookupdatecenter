#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
simulator="${1:?Pass the UDID of a booted iPad simulator}"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-ipad-waveform-display.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 scripts/ipad-track-controls-fixture.py "$test_dir"
python3 - "$test_dir" <<'PY'
from pathlib import Path
import os, sys
folder = Path(sys.argv[1])
paths = ['Application/Project/AudioFileRead.swift', 'Apple/Shared/TimelineRenderDiagnostics.swift',
         'Apple/Shared/TimelineAudioWaveform.swift', 'Apple/Shared/MetalWaveformRenderer.swift',
         'Tests/Apple/IpadWaveformDisplayFixture.swift']
sources = [Path(path).read_text() for path in paths]
# Production now includes its own Simulator presentation callback fallback.
renderer = sources[3]
negative = os.environ.get('CATLIVE_WAVEFORM_DISPLAY_NEGATIVE') == '1'
if negative:
    assert renderer.count('        setNeedsDisplay()') == 1
    renderer = renderer.replace('        setNeedsDisplay()', '        draw()')
sources[3] = renderer
source = '\n'.join(sources)
source += '\nextension MetalWaveformSurface { var displayedOriginForPanTest: CGFloat? { presented?.coordinateSpace?.documentOrigin.x }; var displayedScaleForZoomTest: Double? { presented?.coordinateSpace?.pixelsPerSecond } }\n'
(folder / 'Fixture.swift').write_text(source)
tests = Path('Tests/Apple/IpadWaveformDisplayUITests.swift').read_text()
if negative:
    tests = tests.replace('result.label.hasPrefix("PASS:")', 'result.label.hasPrefix("FAIL: waveform rendered before UIKit\'s item display pass")')
(folder / 'tests.swift').write_text(tests)
PY
xcodebuild -project "$test_dir/Fixture.xcodeproj" -scheme Fixture \
    -destination "platform=iOS Simulator,id=$simulator" -derivedDataPath "$test_dir/derived" \
    -jobs 2 -collect-test-diagnostics never ONLY_ACTIVE_ARCH=YES test
