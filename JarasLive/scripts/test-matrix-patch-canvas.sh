#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-matrix-canvas.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/MatrixPatchView.swift').read_text()
models = source[source.index('private struct MatrixPatchRow'):source.index('struct MatrixPatchView:')]
canvas = source[source.index('private final class MatrixPatchSurface:'):source.rindex('#endif')]
tip = Path('Apple/Shared/NativeTooltips.swift').read_text()
tip = tip[tip.index('@MainActor final class DesktopIconTooltipWindow'):tip.rindex('#endif')]
destination = Path('Application/Project/MatrixPatch.swift').read_text()
destination = destination[destination.index('public enum MatrixPatchDestination'):destination.index('public extension Song')]
prelude = '''import AppKit
import SwiftUI
struct ProjectError: Error { static func invalid(_ text: String) -> ProjectError { ProjectError() } }
enum JarasLocalization { static func string(_ text: String) -> String { text } }
'''
Path(sys.argv[1]).write_text(prelude + Path('Application/Project/OutputPatch.swift').read_text() + destination + models + tip + canvas + Path('Tests/Apple/MatrixPatchCanvasTests.swift').read_text())
PY
swiftc -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
