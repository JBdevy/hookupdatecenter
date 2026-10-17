#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-project-activation.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" "${CATLIVE_PROJECT_DOCUMENTS_TEST_SOURCE:-Apple/Shared/ProjectDocuments.swift}" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[2]).read_text()
activate_start = source.index('        canCancelOpening = false', source.index('    private func activate('))
activate = source[activate_start:source.index('        let missing = ', activate_start)]
finish_start = source.index('                if currentURL != url { try await rememberProjectMedia() }', source.index('    private func finish(scan:'))
finish = source[finish_start:source.index('                StemAudioPlayback.shared.open', finish_start)]
helpers = source[source.index('    private func closeProjectEditors()'):source.index('    private func activate(')]
pending = source[source.index('    struct PendingAudioDrop:'):source.index('    @Published var pendingAudioDrop:')]
main_view = Path('Apple/Shared/MainView.swift').read_text()
drop_start = main_view.index('                AudioDropOptions { layout, gap in', main_view.index('.sheet(item: $documents.pendingAudioDrop)'))
drop_start = main_view.index('\n', drop_start) + 1
drop_confirmation = main_view[drop_start:main_view.index('\n                }', drop_start)]
selection_source = Path('Apple/Shared/GridSelectionInput.swift').read_text()
area_selection = selection_source[selection_source.index('@MainActor final class TimelineAreaSelection:'):selection_source.index('\nstruct GridSelectionItem')]
fixture = Path('Tests/Apple/ProjectActivationCommitTests.swift').read_text()
fixture = fixture.replace('        // INSERT_ACTIVATION_COMMIT', activate).replace('        // INSERT_CREATION_COMMIT', finish).replace('    // INSERT_SESSION_HELPERS', helpers)
fixture = fixture.replace('    // INSERT_PENDING_DROP_TYPE', pending).replace('        // INSERT_DROP_CONFIRMATION', drop_confirmation)
Path(sys.argv[1]).write_text('import Combine\n' + Path('Apple/Shared/AudioExportSelection.swift').read_text() + '\n' + area_selection + '\n' + fixture)
PY
swiftc Application/Project/ItemFadeCurve.swift -swift-version 5 "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
