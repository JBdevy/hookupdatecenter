#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/jaras-native-workspace.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
folder=Path(sys.argv[1])
fx=Path('Apple/Shared/FXEditor.swift').read_text()
text=Path('Apple/Shared/TextItemEditor.swift').read_text()
region=Path('Apple/Shared/RegionEditor.swift').read_text()
(folder/'environment.swift').write_text(fx[:fx.index('enum FXModelLookup')]+text[:text.index('/// The draft')]+region[region.index('/// Immutable menu target:'):])
source=Path('Apple/Shared/TimelineGridView.swift').read_text()
start=source.index('struct MixerResizeHandle:')
(folder/'divider.swift').write_text('import SwiftUI\nimport AppKit\n'+source[start:source.index('\n#endif',start)])
row_start=source.index('private struct TimelineMixerRowVersion<')
row_version=source[row_start:source.index('\n#endif',row_start)]
observer_start=source.index('@MainActor private final class TimelineMixerRowUpdates<')
row_version += '\n' + source[observer_start:source.index('private struct TimelineLiveMixerRow<', observer_start)]
(folder/'main.swift').write_text('import SwiftUI\nimport Combine\nsetbuf(stdout, nil)\n'+row_version+'\n'+Path('Tests/Apple/NativeWorkspaceSplitTests.swift').read_text()+'\n'+Path('Tests/Apple/TimelineGeometryRetentionTests.swift').read_text()+'\n'+Path('Tests/Apple/MixerHeaderClickTests.swift').read_text()+'\n'+Path('Tests/Apple/TrackCopyScrollTests.swift').read_text())
mapping=Path('Apple/Shared/ControlMappings.swift').read_text()
right_click=mapping[mapping.index('private struct MappingClickAnchor:'):]
(folder/'right-click.swift').write_text('import SwiftUI\nimport AppKit\n#if os(macOS)\n'+right_click)
workspace=Path('Apple/Shared/GridScrollView.swift').read_text()
workspace=workspace.replace('self.leading.rootView = leading; self.trailing.rootView = trailing',
                            'WorkspaceRootUpdateProbe.count += 1; self.leading.rootView = leading; self.trailing.rootView = trailing')
workspace=workspace.replace('let start = layoutProfile?.beginLayout(self)\n            super.layout()',
                            'if retainsSidebarViewportLayout { WorkspaceMixerLayoutProbe.count += 1 }\n            let start = layoutProfile?.beginLayout(self)\n            super.layout()')
workspace=workspace.replace('        let identity = TimelineGeometryContentIdentity(builder: builderIdentity, blocked: blocked,',
                            '        WorkspaceGeometryIdentityProbe.tokens.append(builderIdentity)\n        let identity = TimelineGeometryContentIdentity(builder: builderIdentity, blocked: blocked,')
workspace=workspace.replace('if commitsFinalRoot && !pendingBuilderUpdate && host != nil { finalLayoutIdentity = contentIdentity }',
                            'if commitsFinalRoot && !pendingBuilderUpdate && host != nil { finalLayoutIdentity = contentIdentity; WorkspaceGeometryFinalLayoutProbe.commit?() }')
(folder/'workspace.swift').write_text(workspace)
setlist=Path('Apple/Shared/SongListView.swift').read_text()
window=setlist[:setlist.index('/// Focus follows')].replace('CatLiveDetachedSetlist', 'CatLiveDetachedSetlistTest')
(folder/'setlist-window.swift').write_text(window)
(folder/'window-test').mkdir()
(folder/'window-test/main.swift').write_text(Path('Tests/Apple/DetachedSetlistWindowTests.swift').read_text())

PY
python3 scripts/track-height-test-geometry.py "$test_dir/TrackHeightGeometry.swift"
swiftc "$test_dir/TrackHeightGeometry.swift" "${JARAS_TEST_OPTIMIZATION:--O}" -g -swift-version 5 -target "${CATLIVE_TEST_ARCH:-$(uname -m)}-apple-macos12.0" Apple/Shared/NativeTimelineInputGate.swift Apple/Shared/RightClickRouting.swift "$test_dir/right-click.swift" "$test_dir/workspace.swift" "$test_dir/environment.swift" "$test_dir/divider.swift" "$test_dir/main.swift" -o "$test_dir/test"
if [[ -n "${CATLIVE_TEST_EXPORT_BINARY:-}" ]]; then
    cp "$test_dir/test" "$CATLIVE_TEST_EXPORT_BINARY"
    if [[ -d "$test_dir/test.dSYM" ]]; then cp -R "$test_dir/test.dSYM" "$CATLIVE_TEST_EXPORT_BINARY.dSYM"; fi
    exit 0
fi
"$test_dir/test"

swiftc -O -swift-version 5 Application/Project/InterfaceScale.swift "$test_dir/setlist-window.swift" "$test_dir/window-test/main.swift" -o "$test_dir/window-test/test"
"$test_dir/window-test/test"
