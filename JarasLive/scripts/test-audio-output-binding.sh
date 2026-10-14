#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
binding_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-output-binding.XXXXXX")"
trap 'rm -rf "$binding_test_dir"' EXIT
python3 - "$binding_test_dir/Test.swift" <<'PY'
import re
import sys
from pathlib import Path

source = Path('Apple/Shared/AudioDeviceSettings.swift').read_text()
names = ['permitConfigurationChange', 'selectInput', 'select', 'bindOutput',
         'suspendOutput', 'outputDeviceDidChange', 'validateOutputBinding',
         'outputIsBound', 'requireSelectedOutput', 'applyBuffer']
methods = []
for name in names:
    match = re.search(r'^    (?:(?:private|fileprivate) )?func ' + re.escape(name) + r'\(', source, re.M)
    if match is None:
        raise SystemExit(f'Production method {name} is missing')
    opening = source.index('{', match.end())
    depth = 1
    cursor = opening + 1
    while depth:
        if source[cursor] == '{': depth += 1
        elif source[cursor] == '}': depth -= 1
        cursor += 1
    methods.append(re.sub(r'\b(?:private|fileprivate) func ', 'func ', source[match.start():cursor]))
# Include the rate/buffer setters but substitute only their environment readers.
for name in ['setSampleRate', 'setBuffer']:
    match = re.search(r'^    func ' + name + r'\(', source, re.M)
    opening = source.index('{', match.end())
    depth = 1
    cursor = opening + 1
    while depth:
        if source[cursor] == '{': depth += 1
        elif source[cursor] == '}': depth -= 1
        cursor += 1
    methods.append(source[match.start():cursor])
fixture = Path('Tests/Apple/AudioOutputBindingTests.swift').read_text()
property_start = source.index('    var outputDeviceIsBound: Bool {')
property_end = source.index('    func requireSelectedOutput(', property_start)
fixture = fixture.replace('    /* OUTPUT_BINDING_PROPERTY */', source[property_start:property_end])
startup_source = Path('Apple/Shared/StemAudioPlayback.swift').read_text()
startup_start = startup_source.index('    private func startEngineIfNeeded()')
startup_end = startup_source.index('    private func prepareDevice()', startup_start)
startup = startup_source[startup_start:startup_end].replace('private func ', 'func ')
license_start = startup_source.index('    func setLicenseAllowed(')
license_end = startup_source.index('    // An independent silent source', license_start)
startup += startup_source[license_start:license_end]
fixture = fixture.replace('    /* OUTPUT_BINDING_METHODS */', '\n'.join(methods))
Path(sys.argv[1]).write_text(fixture.replace('    /* OUTPUT_STARTUP_METHODS */', startup))
PY
swiftc -swift-version 6 -parse-as-library "$binding_test_dir/Test.swift" -o "$binding_test_dir/test"
"$binding_test_dir/test"
