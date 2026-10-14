#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
stop_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-ipad-hardware-stop.XXXXXX")"
trap 'rm -rf "$stop_test_dir"' EXIT
python3 - "$stop_test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/AudioDeviceSettings.swift').read_text()
begin = source.index('final class MobileAudioHardwareStop:')
end = source.index('enum MobileAudioSessionEvent', begin)
Path(sys.argv[1]).write_text('import Foundation\n' + source[begin:end] + Path('Tests/Apple/IpadHardwareStopTests.swift').read_text())
PY
swiftc -swift-version 5 "$stop_test_dir/main.swift" -o "$stop_test_dir/test"
"$stop_test_dir/test"
