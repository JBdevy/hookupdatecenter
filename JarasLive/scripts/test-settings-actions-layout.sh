#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-settings-layout.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
folder = Path(sys.argv[1])
source = Path('Apple/Shared/DAWActionsList.swift').read_text()
needle = '                    .accessibilityAddTraits(category == item ? .isSelected : [])'
assert source.count(needle) == 1
source = source.replace(needle, needle + '\n                    .background(GeometryReader { geometry in Color.clear.preference(key: CategoryFrames.self, value: [item.rawValue: geometry.frame(in: .named("actions"))]) })')
(folder/'main.swift').write_text(source + '\n' + Path('Tests/Apple/SettingsActionsLayoutTests.swift').read_text())
app = folder/'Fixture.app/Contents'
(app/'MacOS').mkdir(parents=True)
for language in ['en', 'pt-BR']:
    target = app/'Resources'/f'{language}.lproj'
    target.mkdir(parents=True)
    (target/'Localizable.strings').write_bytes(Path(f'Apple/Resources/{language}.lproj/Localizable.strings').read_bytes())
PY
swiftc -swift-version 5 Application/Controls/ControlInput.swift Application/Controls/DAWActions.swift "$test_dir/main.swift" -o "$test_dir/Fixture.app/Contents/MacOS/Fixture"
"$test_dir/Fixture.app/Contents/MacOS/Fixture"
