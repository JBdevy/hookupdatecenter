#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-audio-waveform.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/TimelineGridView.swift').read_text()
start = source.index('private func fadedTimelineWaveform(')
end = source.index('private func drawTimelineItem(', start)
stub = '''import SwiftUI
public struct AudioClip {
    var id = UUID()
    var startTime: Double; var duration: Double; var sourceOffset: Double
    var playbackRate: Double; var gain: Double?
    var loopLength: Double? = nil; var loopStart: Double? = nil
    var recordingLane: Int? = nil
    var channelMode: Int? = nil
    var audioRate: Double { playbackRate }
    var fadeIn: Double? = nil; var fadeOut: Double? = nil
    var fadeInCurve: Double? = nil; var fadeOutCurve: Double? = nil
    var fadeInSCurve: Double? = nil; var fadeOutSCurve: Double? = nil
    var fadeTimelineStart: Double? = nil; var fadeTimelineDuration: Double? = nil
}
'''
Path(sys.argv[1]).write_text(stub + source[start:end] + Path('Tests/Apple/TimelineAudioWaveformTests.swift').read_text())
PY
swiftc -O -swift-version 5 Application/Project/ItemFade.swift Application/Project/ItemFadeCurve.swift Application/Project/AudioFileRead.swift Apple/Shared/TimelineAudioWaveform.swift Apple/Shared/ItemWaveformPreview.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
