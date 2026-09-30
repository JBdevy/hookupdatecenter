#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-midi-mappings.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/ControlMappings.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/ControlMappings.swift').read_text().split('\nstruct ControlMappingEditor: View {')[0]
# Expose the MIDI callback and inject a source without requiring hardware.
source = source.replace('private weak var show:', 'weak var show:').replace('private var sources:', 'var sources:').replace('private func receive(', 'func receive(').replace('private func migrateActionMappings(', 'func migrateActionMappings(').replace('private func execute(', 'func execute(')
# The command-line host has no foreground application registration. Replace only
# its active-app gate; test the production key handler and repeat dispatch below.
source = source.replace('guard NSApp.isActive, transferRequest == nil', 'guard mappingTestApplicationActive, transferRequest == nil')
Path(sys.argv[1]).write_text(source)
PY
swiftc -parse-as-library Apple/Shared/NativeTooltips.swift Apple/Shared/NativeTimelineInputGate.swift "$test_dir/ControlMappings.swift" Application/Controls/ControlInput.swift Application/Controls/DAWActions.swift Application/Controls/NativeFXParameter.swift Application/Project/NativeFXSettings.swift Application/Project/MIDIFaderValue.swift Tests/Apple/MIDIMappingTests.swift -o "$test_dir/mapping-tests"
"$test_dir/mapping-tests"
