#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-add-project-flow.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PY'
from pathlib import Path
import sys
source=Path('Apple/Shared/ProjectDocuments.swift').read_text()
methods=source[source.index('    func addProject()'):source.index('    private func analyzeFolders(')]
finish=source[source.index('    private func finish(scan:'):source.index('        do { try ProjectDirectoryPolicy.validate(url) }',source.index('    private func finish(scan:'))]
# Stop exactly at destination resolution, before validation, media I/O or saving.
finish+='        resolvedURL = url\n        #endif\n    }\n'
state='''
@MainActor final class ProjectDocuments {
    var ready = false, busy = false, adding = false, showingOpenProjectAlert = false
    var currentURL: URL?
    var folderReview: [URL]?
    var folders: [URL] = [], selectedFolders: [URL] = []
    var scan: StemScan?
    var removal = "", error = "", status = ""
    var warnings: [String] = []
    private var appendDestination: (project: UUID, url: URL)?
    let show = FixtureShow()
    var analyzed: [[URL]] = []
    var resolvedURL: URL?
    var hasAppendDestination: Bool { appendDestination != nil }
    private func analyzeFolders(_ urls: [URL]) { analyzed.append(urls); scan = StemScan() }
    func resolveImportDestination() { finish(scan: scan, detectBPM: false) }
'''
review=Path('Apple/Shared/FolderImportReview.swift').read_text()
review=review[review.index('struct FolderImportReview: View {'):review.index('    var body: some View {')]
review=review.replace('struct FolderImportReview: View {','struct FolderImportReview {',1)
review+='    var testedSelection: FolderImportSelection { selection }\n}\n'
fixture=Path('Tests/Apple/AddProjectFlowTests.swift').read_text()
assert fixture.count('// EXTRACTED_PRODUCTION_TYPES') == 1
Path(sys.argv[1]).write_text(fixture.replace('// EXTRACTED_PRODUCTION_TYPES',state+methods+finish+'}\n'+review))
PY
swiftc -swift-version 5 Application/Project/FolderImportSelection.swift "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
