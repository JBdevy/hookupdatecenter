#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-fx-reorder.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT
python3 - "$fixture_dir/main.swift" <<'PY'
from pathlib import Path
import sys
mac=Path('Apple/Shared/ExternalPluginEditor.swift').read_text()
start=mac.index('    func tableView(_ tableView: NSTableView, pasteboardWriterForRow')
delegates=mac[start:mac.index('    @discardableResult private func moveEffect', start)]
mac=mac[mac.index('private final class FXChainEffectNameView:'):mac.index('@MainActor final class TrackFXChainView:')]
native=Path('Apple/Shared/FXEditor.swift').read_text()
native=native[native.index('struct ClipFXReorderPayload:'):native.index('struct ClipFXReorderDrop:')]
fixture=Path('Tests/Apple/ItemFXReorderInputTests.swift').read_text().replace('    // FX_CHAIN_DRAG_DELEGATES', delegates)
Path(sys.argv[1]).write_text(fixture+'\n'+mac+'\n'+native)
PY
swiftc -swift-version 5 -default-isolation MainActor -I .build/out/Products/Debug -L .build/out/Products/Debug -lJarasApplication "$fixture_dir/main.swift" -o "$fixture_dir/test"
"$fixture_dir/test"
