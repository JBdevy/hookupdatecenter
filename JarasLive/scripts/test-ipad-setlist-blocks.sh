#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-ipad-setlist-blocks.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/fixture.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/DAWRemoteView.swift').read_text()
def declaration(marker):
    start = source.index(marker)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        if source[end] == '{': depth += 1
        elif source[end] == '}': depth -= 1
        end += 1
    return source[start:end].replace('private func ', 'func ', 1).replace('private struct ', 'struct ', 1)
fixture = Path('Tests/Apple/IpadSetlistBlockDeletionTests.swift').read_text()
fixture = fixture.replace('// PRODUCTION_NATIVE_SETLIST_REMOVAL', declaration('private struct NativeSetlistRemoval'))
methods = ['selectSetlistEntry', 'prepareNativeSetlistDrag', 'deleteNativeSelection', 'requestNativeSetlistRemoval', 'confirmNativeSetlistRemoval', 'remoteSetlistBlockNumber', 'performRemoteBlockMIDI']
fixture = fixture.replace('// PRODUCTION_NATIVE_SETLIST_ACTIONS', '\n'.join(declaration('private func ' + name + '(') for name in methods))
block_row = declaration('private func setlistBlockRow(')
assert '.onDrag' in block_row and 'prepareNativeSetlistDrag(block.id)' in block_row, 'Block rows must start the same native drag as songs'
assert '.onDrop' in block_row and 'target: block.id' in block_row, 'Block rows must also accept before/after drops'
Path(sys.argv[1]).write_text(fixture)
PY
swiftc -swift-version 5 -parse-as-library \
  Application/Controls/ControlInput.swift Application/Controls/HardwareKeyboardInput.swift \
  "$test_dir/fixture.swift" -o "$test_dir/test"
"$test_dir/test"
