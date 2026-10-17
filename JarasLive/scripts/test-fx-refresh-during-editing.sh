#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-fx-refresh.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
python3 - "$build_dir/Views.swift" <<'PY'
from pathlib import Path
import sys

def declaration(path, name):
    text = Path(path).read_text()
    begin = text.index(name)
    pos = text.index('{', begin)
    depth = 1
    end = pos + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[begin:end]

Path(sys.argv[1]).write_text('import SwiftUI\nimport Combine\n' +
    declaration('Apple/Shared/StemAudioPlayback.swift', '@MainActor final class TrackMeterLevel') + '\n' +
    declaration('Apple/Shared/FXControls.swift', 'struct EffectVerticalMeters'))
PY
swiftc -swift-version 5 -parse-as-library "$build_dir/Views.swift" \
    Apple/Shared/EQRTAOverlay.swift Apple/Shared/EQRealTimeAnalysis.swift Apple/Shared/EffectSpectrogram.swift \
    Tests/Apple/FXRefreshDuringEditingTests.swift -framework Accelerate -o "$build_dir/test"
"$build_dir/test"
