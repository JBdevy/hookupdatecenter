import XCTest
@testable import JarasApplication

@MainActor private final class ClipboardExecutor: CommandExecutor {
    var project = Project.empty(name: "Clipboard")
    var transport = TransportState(playing: false, position: 7, editPosition: 100, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0))
    var pastes = 0, loads = 0, reads = 0
    func load(_ value: Project) throws { try value.validate(); project = value; transport.songId = value.songs[0].id; loads += 1 }
    func snapshot() throws -> ShowSnapshot { reads += 1; return ShowSnapshot(project: project, transport: transport) }
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: transport) }
    func pasteItems(_ entries: [GridItemClipboard.Entry], song: UUID, moving: Bool) throws { try project.pasteItems(entries, song: song, moving: moving); pastes += 1 }
    func applyProjectEdit(_ value: Project) throws { project = value }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws {}
    func addTrack(id: UUID, name: String, role: TrackRole) throws {}
    func advance(_ elapsed: Double) {}
    func finishCurrentSong(_ enabled: Bool) {}
}

final class GridItemClipboardTests: XCTestCase {
    private func fixture() -> Project {
        var project = Project.empty(name: "Clipboard")
        var fx = NativeFXSettings(); fx.inserted = ["EQ", "Compressor"]; fx.eqEnabled = true; fx.bands[1].gain = 5
        var first = Track(id: UUID(), name: "First", role: .keys)
        first.clips = [AudioClip(id: UUID(), name: "Stem", startTime: 10, duration: 5, sourceOffset: 1,
            waveform: [0.1, 0.3], audioFile: AudioFile(path: "Steams/original.wav"), gain: 0.5,
            waveformChannels: [[0.1, 0.3], [0.2, 0.4]], muted: true, playbackRate: 1.2, loopStart: 1, loopLength: 3, fx: fx, fxBypassed: true)]
        var second = Track(id: UUID(), name: "Second", role: .bass)
        second.clips = [AudioClip(id: UUID(), name: "Other", startTime: 20, duration: 5, audioFile: AudioFile(path: "Steams/other.wav"))]
        project.songs[0].tracks = [first, second]; project.songs[0].duration = 40
        return project
    }
    func testCopySharesSourceAndWaveformsButHasIndependentFXGainAndMute() throws {
        var project = fixture(); let original = project.songs[0].tracks[0].clips[0]
        let clipboard = try XCTUnwrap(GridItemClipboard(project: project, song: project.songs[0].id, selected: [original.id]))
        let entries = try clipboard.items(in: project, at: 100)
        try project.pasteItems(entries, song: clipboard.song, moving: false)
        var expected = original; expected.id = entries[0].clip.id; expected.startTime = 100
        XCTAssertEqual(project.songs[0].tracks[0].clips[1], expected)
        XCTAssertNotEqual(expected.id, original.id)
        XCTAssertEqual(project.mediaPaths, ["Steams/original.wav", "Steams/other.wav"])
        let copiedWave = expected.waveform.withUnsafeBufferPointer { $0.baseAddress }
        XCTAssertEqual(copiedWave, original.waveform.withUnsafeBufferPointer { $0.baseAddress })
        project.songs[0].tracks[0].clips[1].gain = 0.25
        project.songs[0].tracks[0].clips[1].muted = false
        project.songs[0].tracks[0].clips[1].fx!.bands[1].gain = -7
        XCTAssertEqual(project.songs[0].tracks[0].clips[0], original)
    }
    func testMultipleItemsPreserveTrackAndTimeOffsetsAndEachPasteHasNewIDs() throws {
        var project = fixture()
        let ids = Set(project.songs[0].tracks.flatMap(\.clips).map(\.id))
        let clipboard = try XCTUnwrap(GridItemClipboard(project: project, song: project.songs[0].id, selected: ids))
        let first = try clipboard.items(in: project, at: 100)
        XCTAssertEqual(first.map { $0.clip.startTime }, [100, 110])
        XCTAssertEqual(first.map(\.track), project.songs[0].tracks.map(\.id))
        try project.pasteItems(first, song: clipboard.song, moving: false)
        let second = try clipboard.items(in: project, at: 200)
        XCTAssertTrue(Set(first.map { $0.clip.id }).isDisjoint(with: second.map { $0.clip.id }))
        try project.pasteItems(second, song: clipboard.song, moving: false)
        XCTAssertEqual(project.songs[0].tracks.map { $0.clips.count }, [3, 3])
    }
    func testPendingMovePreservesOriginalUntilPasteAndUsesLatestItemState() throws {
        var project = fixture(); let before = project
        let original = project.songs[0].tracks[0].clips[0]
        let clipboard = try XCTUnwrap(GridItemClipboard(project: project, song: project.songs[0].id, selected: [original.id], moving: true))
        XCTAssertEqual(project, before)
        project.songs[0].tracks[0].clips[0].gain = 0.75
        let entries = try clipboard.items(in: project, at: 80)
        try project.pasteItems(entries, song: clipboard.song, moving: true)
        XCTAssertEqual(project.songs[0].tracks[0].clips.count, 1)
        XCTAssertEqual(project.songs[0].tracks[0].clips[0].id, original.id)
        XCTAssertEqual(project.songs[0].tracks[0].clips[0].gain, 0.75)
        XCTAssertEqual(project.songs[0].tracks[0].clips[0].startTime, 80)
    }
    func testFailedMoveIsAtomicAndRemainsAvailableToPasteElsewhere() throws {
        var project = Project.empty(name: "Text")
        var track = Track(id: UUID(), name: "Teleprompter", role: TrackRole(rawValue: "teleprompt"))
        track.clips = [AudioClip(id: UUID(), name: "One", startTime: 0, duration: 10, text: "One"), AudioClip(id: UUID(), name: "Two", startTime: 20, duration: 10, text: "Two")]
        project.songs[0].tracks = [track]; project.songs[0].duration = 60
        let clipboard = try XCTUnwrap(GridItemClipboard(project: project, song: project.songs[0].id, selected: [track.clips[0].id], moving: true))
        let before = project
        XCTAssertThrowsError(try project.pasteItems(clipboard.items(in: project, at: 20), song: clipboard.song, moving: true))
        XCTAssertEqual(project, before)
        try project.pasteItems(clipboard.items(in: project, at: 40), song: clipboard.song, moving: true)
        XCTAssertEqual(project.songs[0].tracks[0].clips.first { $0.id == track.clips[0].id }?.startTime, 40)
        var other = project; other.id = UUID()
        XCTAssertThrowsError(try clipboard.items(in: other, at: 0))
    }
    @MainActor func testControllerPastesAtGreenCursorInOneUndoableEditWithoutReloadingProject() throws {
        let project = fixture(), executor = ClipboardExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        let original = project.songs[0].tracks[0].clips[0]
        let reads = executor.reads
        XCTAssertTrue(show.copyItems([original.id], moving: true))
        XCTAssertEqual(show.snapshot.project, project); XCTAssertFalse(show.hasUnsavedChanges)
        let ids = show.pasteItems()
        XCTAssertEqual(ids, [original.id])
        XCTAssertEqual(show.current?.tracks[0].clips[0].startTime, 100, "paste follows editPosition, independently of playback position")
        XCTAssertEqual(executor.loads, 1); XCTAssertEqual(executor.reads, reads); XCTAssertEqual(executor.pastes, 1)
        show.undo(); XCTAssertEqual(show.snapshot.project, project)
        show.redo(); XCTAssertEqual(show.current?.tracks[0].clips[0].startTime, 100)
        let copies = show.pasteItems()
        XCTAssertEqual(copies.count, 1); XCTAssertFalse(copies.contains(original.id), "the completed move becomes a reusable copy")
    }
}
