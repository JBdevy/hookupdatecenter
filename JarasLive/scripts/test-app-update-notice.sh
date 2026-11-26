#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-update-notice.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/titlebar.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Apple/Shared/ProjectDocuments.swift').read_text()
start = source.index('private final class ProjectTitlebarVersionView:')
end = source.index('\nfinal class ProjectTitlebarAnchor', start)
view = source[start:end].replace('private final class ProjectTitlebarVersionView:', 'final class ProjectTitlebarVersionView:', 1)
Path(sys.argv[1]).write_text('''import AppKit
extension NSFont {
    static func jarasSystemFont(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }
}
''' + view)
PY
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos12.0" Apple/Shared/AppUpdateNotice.swift "$test_dir/titlebar.swift" Tests/Apple/AppUpdateNoticeTests.swift -o "$test_dir/test"
"$test_dir/test"
