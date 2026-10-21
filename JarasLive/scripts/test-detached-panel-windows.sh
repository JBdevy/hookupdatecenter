#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-detached-panels.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PYTHON'
from pathlib import Path
import sys
out = Path(sys.argv[1])
s = """import SwiftUI
import AppKit
final class ShowController {}
struct TrackDetailsEditRequest {}
@MainActor final class InterfaceScaling { static let shared = InterfaceScaling(); func register(_ window: NSWindow) {} }
"""
# Exercise the production controllers with lightweight content, isolated from the audio engine.
for file, name, content in [
    ('TrackMixerRow.swift', 'Mixer', 'DetachedMixerContent(show: show, owner: self, openFX: openFX, editTrack: editTrack).interfaceScaled()'),
    ('SmoothSeekPanel.swift', 'Parts', 'DetachedPartsContent(show: show).interfaceScaled()')]:
    source = Path('Apple/Shared', file).read_text()
    start = source.index('@MainActor final class Detached' + name + 'Window')
    end = source.index('private struct Detached' + name + 'Content', start)
    s += source[start:end].replace(content, 'Text("Geometry fixture")').replace('CatLiveDetached' + name, 'CatLiveTestDetached' + name).replace('jaras.layout.', 'jaras.testlayout.')
s += Path('Tests/Apple/DetachedPanelWindowTests.swift').read_text()
(out / 'test.swift').write_text(s)
PYTHON
swiftc -parse-as-library Apple/Shared/ProjectionWindow.swift "$test_dir/test.swift" -o "$test_dir/test"
"$test_dir/test"
