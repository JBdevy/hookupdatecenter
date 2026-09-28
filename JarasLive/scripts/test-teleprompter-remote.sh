#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d /tmp/jaras-tp-remote.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
directory = Path(sys.argv[1])
source = Path('Apple/Shared/TeleprompterRemote.swift').read_text()
prefix = source[:source.index('@MainActor final class TeleprompterRemote:')]
(directory/'Server.swift').write_text(prefix + '\n#endif\n')
(directory/'main.swift').write_text(Path('Tests/Apple/TeleprompterRemoteTests.swift').read_text())
PY
swiftc -swift-version 5 Application/Project/TeleprompterSettings.swift "$test_dir/Server.swift" "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
