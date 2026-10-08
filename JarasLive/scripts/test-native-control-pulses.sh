#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/catlive-control-pulses.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/main.swift" <<'PYTEST'
from pathlib import Path
import sys

theme = Path('Apple/Shared/Theme.swift').read_text()
colors = theme[:theme.index('    static func track(')] + '}\n'
colors += theme[theme.index('extension Color {'):theme.index('struct StageButtonStyle:')]
blink = theme[theme.index('struct JarasBlink:'):theme.index('/// A color drag')]
transport = Path('Apple/Shared/TransportView.swift').read_text()
metrics = transport[transport.index('enum TransportControlMetrics'):transport.index('struct TransportPreview:')]
metronome = transport[transport.index('private struct MetronomeControl:'):transport.index('private struct MetronomeEditor:')]
mapping = Path('Apple/Shared/ControlMappings.swift').read_text()
right_click = mapping[mapping.index('private struct MappingClickAnchor:'):mapping.index('private struct ImmediateRightClick:')]
right_click = '#if os(macOS)\n' + right_click
right_click += mapping[mapping.index('private struct ImmediateRightClick:'):mapping.index('\n}', mapping.index('extension View {\n    func immediateRightClick')) + 2]
source = colors + blink + metrics + metronome + right_click
source = source.replace('private struct', 'struct').replace('private final class', 'final class')
# Instrument only this generated fixture, so production views carry no counter.
source = source.replace('    required init(rootView: AnyView)',
    '    var layoutCount = 0\n    override func layout() { layoutCount += 1; super.layout() }\n    required init(rootView: AnyView)')
source = source.replace('    private func refreshSong(_ snapshot: ShowSnapshot) {',
    '    var songRefreshCount = 0\n    private func refreshSong(_ snapshot: ShowSnapshot) {\n        songRefreshCount += 1')
tempo = Path('Application/Project/TimelineTempo.swift').read_text()
section_start = tempo.index('public struct TimelineTempoSection:')
section = tempo[section_start:tempo.index('public extension Song {', section_start)]
methods = tempo[tempo.index('    func tempoSections(until'):tempo.index('    /// Persisted attachment wins')]
stubs = '''
enum ProjectTimebase { case free, relative }
enum TempoMarkerTimebase { case global, free, relative
    func resolved(project: ProjectTimebase) -> ProjectTimebase {
        switch self { case .global: return project; case .free: return .free; case .relative: return .relative }
    }
}
struct ProjectTimeSettings { var timebase = ProjectTimebase.relative }
struct TimelineMarker {
    let id: UUID; var position: Double; var tempoBPM: Double?
    var tempoBeats: Int? = nil; var tempoUnit: Int? = nil
    var tempoTimebase: TempoMarkerTimebase? = nil; var tempoReferenceBPM: Double? = nil
    var regionOwnerID: UUID? = nil
    var isTempo: Bool { tempoBPM != nil }
}
struct Song {
    let id: UUID; var duration = 120.0; var bpm = 120.0
    var meterBeats = 4, meterUnit = 4
    var markers: [TimelineMarker]? = nil
    var projectTime = ProjectTimeSettings()
}
struct TransportState { var songId: UUID?; var playing = true; var position = 0.0 }
struct Project { var songs: [Song] }
struct ShowSnapshot { var project: Project; var transport: TransportState }
@MainActor final class ShowProjectPresentation: ObservableObject { let objectWillChange = ObservableObjectPublisher() }
@MainActor final class ShowController: ObservableObject {
    @Published var snapshot: ShowSnapshot
    let projectPresentation = ShowProjectPresentation()
    init(song: Song) { snapshot = ShowSnapshot(project: Project(songs: [song]), transport: TransportState(songId: song.id)) }
    func sample(_ position: Double, playing: Bool = true) {
        var next = snapshot; next.transport.position = position; next.transport.playing = playing; snapshot = next
    }
    func editSong(_ song: Song) {
        var next = snapshot; next.project.songs = [song]; snapshot = next
        projectPresentation.objectWillChange.send()
    }
}
@MainActor final class MetronomeSettings: ObservableObject {
    static let shared = MetronomeSettings()
    @Published var enabled = true
}
struct ProjectDocuments {}
struct MetronomeEditor: View {
    var body: some View { Text("Metronome settings").frame(width: 220, height: 100)
        .onAppear { PulseJournal.editorOpened += 1 } }
}
'''
Path(sys.argv[1]).write_text('import SwiftUI\nimport AppKit\nimport Combine\n' +
    stubs + section.replace('public ', '') + '\nextension Song {\n' + methods + '}\n' +
    source + '\n' + Path('Tests/Apple/NativeControlPulseTests.swift').read_text().replace('precondition(', 'expect('))
PYTEST
swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos12.0" \
    Apple/Shared/RightClickRouting.swift Apple/Shared/NativeTooltips.swift \
    "$test_dir/main.swift" -o "$test_dir/test"
"$test_dir/test"
