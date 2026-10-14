#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
notice_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-migration-notice.XXXXXX")"
trap 'rm -rf "$notice_test_dir"' EXIT
mkdir -p "$notice_test_dir/Notice.app/Contents/MacOS" "$notice_test_dir/Notice.app/Contents/Resources"
cp -R Apple/Resources/en.lproj Apple/Resources/pt-BR.lproj "$notice_test_dir/Notice.app/Contents/Resources/"
python3 - "$notice_test_dir" <<'PY'
from pathlib import Path
import sys, plistlib
folder=Path(sys.argv[1])
app=folder/'Notice.app'/'Contents'
(app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'Notice','CFBundleIdentifier':'com.catlive.test.migration-notice','CFBundleDevelopmentRegion':'en','CFBundleLocalizations':['en','pt-BR']}))
source=Path('Apple/Shared/JarasLiveApp.swift').read_text()
notice=source[source.index('struct ProjectMigrationNotice:'):source.index('struct UnauthorizedPreview:')]
for role in ['header','details','ok']:
    original=f'.accessibilityIdentifier("migration-notice-{role}")'
    notice=notice.replace(original, original+f'.background(MigrationLayoutProbe(role: "{role}"))')
localization=Path('Apple/Shared/NativeTooltips.swift').read_text()
localization=localization[localization.index('enum JarasLocalization {'):localization.index('extension View {')]
colors='enum JarasTheme { static let background = Color.black, panel = Color.gray, secondary = Color.gray, yellow = Color.yellow }\n'
(folder/'main.swift').write_text('import AppKit\nimport SwiftUI\n'+colors+localization+notice+Path('Tests/Apple/ProjectMigrationNoticeTests.swift').read_text())
PY
swiftc -swift-version 5 -target "$(uname -m)-apple-macos12.0" "$notice_test_dir/main.swift" -o "$notice_test_dir/Notice.app/Contents/MacOS/Notice"
"$notice_test_dir/Notice.app/Contents/MacOS/Notice"
