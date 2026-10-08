#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-region-popovers.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source=Path('Apple/Shared/TimelineGridView.swift').read_text()
start=source.index('    @ViewBuilder private func regionEditorAnchors(')
end=source.index('    #if !os(macOS)',start)
helper=source[start:end]
eager='''.popover(isPresented: Binding(get: { editingRegion == part.id }, set: { if !$0 { editingRegion = nil } })) {
 RegionEditor(region: part, initialColor: part.color ?? 0x705264) { name, color, uppercase in
 show.editRegion(part.id, name: name, color: color, uppercaseName: uppercase)
 }
}.popover(isPresented: Binding(get: { unifyingRegion == part.id }, set: { if !$0 { unifyingRegion = nil } })) {
 UnifyRegionEditor { show.unifyRegions(containing: part.id, name: $0) }
}'''
editor=Path('Apple/Shared/RegionEditor.swift').read_text().split('#if os(macOS)')[0]
fixtures=[]
lazy = '''ZStack(alignment: .topLeading) {
 HitSurface(id: part.id).frame(width: width, height: 24)
 if editingRegion == part.id || unifyingRegion == part.id {
  Color.clear.frame(width: width, height: 24).background { regionEditorAnchors(part, index: index) }
 }
}'''
for name,body in [('LazyRegionFixture',lazy),('EagerRegionFixture','HitSurface(id: part.id).frame(width: width, height: 24)\n'+eager)]:
 fixtures.append('''struct '''+name+''': View {
 @ObservedObject var show: FixtureState
 let index: Int
 let width: CGFloat
 @Environment(\\.locale) var locale
 var part: Part { show.parts[index] }
 var editingRegion: UUID? { get { show.editing } nonmutating set { show.editing=newValue } }
 var unifyingRegion: UUID? { get { show.unifying } nonmutating set { show.unifying=newValue } }
 var body: some View {
 '''+body+'''
 }
 '''+(helper if name == 'LazyRegionFixture' else '')+'''
}
''')
Path(sys.argv[1]).write_text(editor+'\n'+'\n'.join(fixtures)+'\n'+Path('Tests/Apple/RegionPopoverTests.swift').read_text())
PY
swiftc -suppress-warnings -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
