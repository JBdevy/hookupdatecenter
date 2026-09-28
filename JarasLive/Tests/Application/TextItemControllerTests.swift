import XCTest
@testable import JarasApplication

@MainActor private final class TextItemExecutor: CommandExecutor {
    var project = Project.empty(name: "Text")
    var transport = TransportState(playing: false, position: 15, editPosition: 27, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 3))
    var snapshotReads = 0, insertions = 0, textEdits = 0, fullEdits = 0
    var reject = false
    func load(_ project: Project) throws { self.project = project; transport.songId = project.songs.first?.id }
    func snapshot() throws -> ShowSnapshot { snapshotReads += 1; return ShowSnapshot(project: project, transport: transport) }
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: transport) }
    func addRecordedClip(_ clip: AudioClip, track: UUID) throws {
        if reject { throw ProjectError.invalid("Rejected") }
        guard let song = project.songs.firstIndex(where: { $0.tracks.contains { $0.id == track } }),
              let row = project.songs[song].tracks.firstIndex(where: { $0.id == track }) else { throw ProjectError.invalid("Missing track") }
        project.songs[song].tracks[row].clips.append(clip)
        project.songs[song].duration = max(project.songs[song].duration, clip.startTime + clip.duration)
        insertions += 1
    }
    func setClipText(_ id: UUID, text: String) throws {
        if reject { throw ProjectError.invalid("Rejected") }
        try AudioClip.validateText(text)
        for song in project.songs.indices {
            for track in project.songs[song].tracks.indices {
                if let item = project.songs[song].tracks[track].clips.firstIndex(where: { $0.id == id }) {
                    project.songs[song].tracks[track].clips[item].text = text
                    textEdits += 1
                    return
                }
            }
        }
        throw ProjectError.invalid("Missing item")
    }
    func applyProjectEdit(_ project: Project) throws { self.project = project; fullEdits += 1 }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws {}
    func addTrack(id: UUID, name: String, role: TrackRole) throws {}
    func advance(_ elapsed: Double) {}
    func finishCurrentSong(_ enabled: Bool) {}
}

final class TextItemControllerTests: XCTestCase {
    private func fixture() -> Project {
        var project = Project.empty(name: "Lyrics and chords")
        project.songs[0].duration = 20
        project.songs[0].tracks = [
            Track(id: UUID(), name: "Teleprompter", role: .init(rawValue: "teleprompt")),
            Track(id: UUID(), name: "Chords", role: .chords),
            Track(id: UUID(), name: "Audio", role: .other)
        ]
        return project
    }
    @MainActor func testAddUsesEditCursorTenSecondsAndOneUndoWithoutProjectSerialization() throws {
        for role in ["teleprompt", "chords"] {
            let project = fixture(), executor = TextItemExecutor()
            let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
            let track = try XCTUnwrap(show.current?.tracks.first { $0.role.rawValue == role })
            let transport = show.snapshot.transport, reads = executor.snapshotReads
            let item = try XCTUnwrap(show.addTextItem(track: track.id))
            let clip = try XCTUnwrap(show.current?.tracks.first { $0.id == track.id }?.clips.first)
            XCTAssertEqual(clip.id, item)
            XCTAssertEqual(clip.startTime, 27); XCTAssertEqual(clip.duration, 10)
            XCTAssertEqual(clip.text, ""); XCTAssertNil(clip.audioFile)
            XCTAssertEqual(show.current?.duration, 37)
            XCTAssertEqual(show.snapshot.transport, transport)
            XCTAssertEqual(executor.snapshotReads, reads)
            XCTAssertEqual(executor.insertions, 1); XCTAssertEqual(executor.fullEdits, 0)
            XCTAssertTrue(show.hasUnsavedChanges); XCTAssertTrue(show.canUndo)
            try show.snapshot.project.validate()
            show.undo()
            XCTAssertTrue(show.current?.tracks.first { $0.id == track.id }?.clips.isEmpty == true)
            show.redo()
            XCTAssertEqual(show.current?.tracks.first { $0.id == track.id }?.clips.first?.id, item)
        }
    }
    @MainActor func testTextCommitsOneScalarRetainsBothClocksAndAllowsUndo() throws {
        let executor = TextItemExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: fixture())
        let track = try XCTUnwrap(show.current?.tracks.first)
        let id = try XCTUnwrap(show.addTextItem(track: track.id))
        let before = show.snapshot.transport, reads = executor.snapshotReads, revision = show.projectRevision
        let text = "C  G/B  Am\nGraça e paz 🎵"
        XCTAssertTrue(show.updateTextItem(id, text: text))
        XCTAssertEqual(show.current?.tracks.first?.clips.first?.text, text)
        XCTAssertEqual(executor.textEdits, 1); XCTAssertEqual(executor.fullEdits, 0)
        XCTAssertEqual(executor.snapshotReads, reads)
        XCTAssertEqual(show.snapshot.transport, before)
        XCTAssertEqual(show.projectRevision, revision + 1)
        XCTAssertTrue(show.updateTextItem(id, text: text))
        XCTAssertEqual(executor.textEdits, 1, "an unchanged draft is not another edit")
        show.undo(); XCTAssertEqual(show.current?.tracks.first?.clips.first?.text, "")
        show.redo(); XCTAssertEqual(show.current?.tracks.first?.clips.first?.text, text)
    }
    @MainActor func testLengthAndTypeGuardsCannotPartiallyMutateOrDirtyProject() throws {
        let executor = TextItemExecutor(), show = try ShowController(executor: TextItemExecutor(), persistence: MemoryProjectStore(), initialProject: fixture())
        let unrelated = try XCTUnwrap(show.current?.tracks.last)
        XCTAssertNil(show.addTextItem(track: unrelated.id)); XCTAssertNil(show.addTextItem(track: UUID()))
        XCTAssertFalse(show.hasUnsavedChanges)
        let bounded = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: fixture())
        let id = try XCTUnwrap(bounded.addTextItem(track: try XCTUnwrap(bounded.current?.tracks.first?.id)))
        let maximum = String(repeating: "🎵", count: 400)
        XCTAssertTrue(bounded.updateTextItem(id, text: maximum))
        let saved = bounded.snapshot.project, revision = bounded.projectRevision
        XCTAssertFalse(bounded.updateTextItem(id, text: maximum + "é"))
        XCTAssertFalse(bounded.updateTextItem(UUID(), text: "Valid"))
        XCTAssertEqual(bounded.snapshot.project, saved); XCTAssertEqual(bounded.projectRevision, revision)
        executor.reject = true
        XCTAssertFalse(bounded.updateTextItem(id, text: "New"))
        XCTAssertNil(bounded.addTextItem(track: try XCTUnwrap(bounded.current?.tracks.first?.id)))
        XCTAssertEqual(bounded.snapshot.project, saved); XCTAssertEqual(bounded.projectRevision, revision)
        XCTAssertEqual(executor.textEdits, 1)
    }
    @MainActor func testAddRejectsOverlapWithoutExecutingOrAddingUndo() throws {
        let executor = TextItemExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: fixture())
        let track = try XCTUnwrap(show.current?.tracks.first?.id)
        _ = try XCTUnwrap(show.addTextItem(track: track))
        let original = show.snapshot.project, revision = show.projectRevision, insertions = executor.insertions
        XCTAssertNil(show.addTextItem(track: track))
        XCTAssertEqual(show.snapshot.project, original)
        XCTAssertEqual(show.projectRevision, revision)
        XCTAssertEqual(executor.insertions, insertions)
    }
}
