import XCTest
@testable import JarasApplication

@MainActor private final class IconExecutor: CommandExecutor {
    var project = Project.empty(name: "Icons")
    var transport = TransportState(playing: true, position: 23, editPosition: 15, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0))
    func load(_ value: Project) throws { project = value; transport.songId = value.songs[0].id }
    func snapshot() throws -> ShowSnapshot { ShowSnapshot(project: project, transport: transport) }
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: transport) }
    func applyProjectEdit(_ value: Project) throws { try value.validate(); project = value }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws {}
    func addTrack(id: UUID, name: String, role: TrackRole) throws {}
    func advance(_ elapsed: Double) {}
    func finishCurrentSong(_ enabled: Bool) {}
}
final class TrackInstrumentIconTests: XCTestCase {
    func testLegacyProjectAndSavedIconsRoundTrip() throws {
        var project = Project.empty(name: "Icons")
        let track = Track(id: UUID(), name: "Piano", role: .keys)
        project.songs[0].tracks = [track]
        let legacy = try JSONEncoder().encode(project)
        XCTAssertFalse(String(decoding: legacy, as: UTF8.self).contains("instrumentIcon"))
        XCTAssertNil(try JSONDecoder().decode(Project.self, from: legacy).songs[0].tracks[0].instrumentIcon)
        for icon in ["piano", "backingVocals", "futureInstrument"] {
            project.songs[0].tracks[0].instrumentIcon = icon
            let reopened = try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(project))
            XCTAssertEqual(reopened.songs[0].tracks[0].instrumentIcon, icon)
        }
    }
    @MainActor func testIconOnlyOnLegacyTrackKeepsDefaultColorAndHistoryEmpty() throws {
        var project = Project.empty(name: "Legacy")
        let track = Track(id: UUID(), name: "Conga", role: .drums)
        project.songs[0].tracks = [track]
        let show = try ShowController(executor: IconExecutor(), persistence: MemoryProjectStore(), initialProject: project)
        show.editTrackDetails([track.id], name: track.name, color: nil, instrumentIcon: "conga", project: project.id)
        XCTAssertFalse(show.canUndo)
        XCTAssertNil(show.current?.tracks[0].color)
        XCTAssertEqual(show.current?.tracks[0].instrumentIcon, "conga")
        show.undo()
        XCTAssertEqual(show.current?.tracks[0].instrumentIcon, "conga")
    }
    @MainActor func testIconsStayOutsideUndoWhileNameAndAudioArePreserved() throws {
        var project = Project.empty(name: "Icons")
        var track = Track(id: UUID(), name: "Piano", role: .keys)
        track.clips = [AudioClip(id: UUID(), name: "Take", startTime: 0, duration: 60, waveform: [0.1, 0.5])]
        track.volume = 0.7; track.pan = -0.3; track.color = 0x828282
        project.songs[0].tracks = [track]
        let show = try ShowController(executor: IconExecutor(), persistence: MemoryProjectStore(), initialProject: project)
        let transport = show.snapshot.transport
        show.editTrackDetails([track.id], name: nil, color: track.color ?? 0x828282, instrumentIcon: "piano", project: project.id)
        // The initial fixture has an explicit color, so only the icon changes.
        XCTAssertFalse(show.canUndo)
        XCTAssertTrue(show.hasUnsavedChanges)
        show.editTrackDetails([track.id], name: "Keys", color: 0xabcdef, instrumentIcon: "piano", project: project.id)
        let changed = try XCTUnwrap(show.current?.tracks.first)
        XCTAssertEqual(changed.instrumentIcon, "piano"); XCTAssertEqual(changed.name, "Keys")
        XCTAssertEqual(changed.clips, track.clips); XCTAssertEqual(changed.volume, track.volume); XCTAssertEqual(changed.pan, track.pan)
        XCTAssertEqual(show.snapshot.transport, transport)
        show.undo(); XCTAssertEqual(show.current?.tracks[0].instrumentIcon, "piano"); XCTAssertEqual(show.current?.tracks[0].name, "Piano")
        XCTAssertTrue(show.canRedo)
        show.editTrackDetails([track.id], name: nil, color: 0x828282, instrumentIcon: nil, project: project.id)
        XCTAssertFalse(show.canUndo); XCTAssertTrue(show.canRedo, "Removing artwork must preserve unrelated Redo")
        show.redo(); XCTAssertNil(show.current?.tracks[0].instrumentIcon)
        XCTAssertEqual(show.current?.tracks[0].name, "Keys")
        show.editTrackDetails([track.id], name: nil, color: 0xabcdef, instrumentIcon: nil, project: project.id)
        XCTAssertNil(show.current?.tracks[0].instrumentIcon)
        XCTAssertEqual(show.snapshot.transport, transport)
        show.editTrackDetails([track.id], name: nil, color: 0, instrumentIcon: "drums", project: UUID())
        XCTAssertNil(show.current?.tracks[0].instrumentIcon, "A stale editor cannot change another project")
    }
}
