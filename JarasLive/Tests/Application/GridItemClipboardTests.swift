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
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws {
        if command == .editSeek { transport.editPosition = value }
    }
    func addTrack(id: UUID, name: String, role: TrackRole) throws {}
    func advance(_ elapsed: Double) {}
    func finishCurrentSong(_ enabled: Bool) {}
}

final class GridItemClipboardTests: XCTestCase {
    @MainActor func testCopyAcrossProjectsPreservesEditsAndStagesIndependentMediaWithUndo() async throws {
        var source = fixture()
        source.songs[0].tracks.insert(Track(id: UUID(), name: "Gap", role: .other), at: 1)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let from = root.appendingPathComponent("Source"), to = root.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: from.appendingPathComponent("Stems"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: to.appendingPathComponent("Stems"), withIntermediateDirectories: true)
        try Data("source audio".utf8).write(to: from.appendingPathComponent("Stems/original.wav"))
        try Data("second audio".utf8).write(to: from.appendingPathComponent("Stems/other.wav"))
        try Data("existing destination audio".utf8).write(to: to.appendingPathComponent("Stems/original.wav"))
        let selected = Set(source.songs[0].tracks.flatMap(\.clips).map(\.id))
        let clipboard = try XCTUnwrap(GridItemClipboard(project: source, song: source.songs[0].id, selected: selected))
        var destination = Project.empty(name: "Other tab")
        destination.songs[0].tracks = (0..<4).map { Track(id: UUID(), name: "Target \($0)", role: .other) }
        let song = destination.songs[0]
        let entries = try clipboard.copiedItems(in: song, at: 73.125, selectedTracks: [song.tracks[3].id, song.tracks[1].id])
        XCTAssertEqual(entries.map(\.track), [song.tracks[1].id, song.tracks[3].id])
        XCTAssertEqual(entries.map { $0.clip.startTime }, [73.125, 83.125])
        XCTAssertTrue(selected.isDisjoint(with: entries.map { $0.clip.id }))
        XCTAssertEqual(entries[0].clip.fx, source.songs[0].tracks[0].clips[0].fx)
        XCTAssertEqual(entries[0].clip.sourceOffset, 1)
        XCTAssertEqual(entries[0].clip.playbackRate, 1.2)
        XCTAssertEqual(entries[0].clip.waveformChannels, source.songs[0].tracks[0].clips[0].waveformChannels)
        let transfer = try GridItemMediaTransfer.stage(entries, from: from, to: to)
        XCTAssertEqual(try Data(contentsOf: to.appendingPathComponent("Stems/original.wav")), Data("existing destination audio".utf8))
        let show = try ShowController(executor: ClipboardExecutor(), persistence: MemoryProjectStore(), initialProject: destination)
        let pasted = try show.pasteTransferredItems(transfer.entries, song: song.id)
        XCTAssertEqual(pasted.count, 2)
        XCTAssertTrue(show.hasUnsavedChanges)
        let saved = try ProjectDocumentCodec.decode(JSONEncoder().encode(show.snapshot.project))
        try FileManager.default.removeItem(at: from)
        for clip in saved.songs[0].tracks.flatMap(\.clips) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: to.appendingPathComponent(clip.audioFile!.path).path))
        }
        show.undo(); XCTAssertEqual(show.snapshot.project, destination)
        show.redo(); XCTAssertEqual(show.current?.tracks.flatMap(\.clips).count, 2)
        // Missing one source rolls back the complete media batch, not a partial paste.
        try FileManager.default.createDirectory(at: from.appendingPathComponent("Stems"), withIntermediateDirectories: true)
        try Data("first file can be copied".utf8).write(to: from.appendingPathComponent("Stems/original.wav"))
        let before = try FileManager.default.contentsOfDirectory(atPath: to.appendingPathComponent("Stems").path)
        XCTAssertThrowsError(try GridItemMediaTransfer.stage(entries, from: from, to: to))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: to.appendingPathComponent("Stems").path), before)
        let cut = try XCTUnwrap(GridItemClipboard(project: source, song: source.songs[0].id, selected: selected, moving: true))
        XCTAssertThrowsError(try cut.copiedItems(in: song, at: 0, selectedTracks: []))
        XCTAssertThrowsError(try clipboard.copiedItems(in: song, at: 0, selectedTracks: [song.tracks[3].id]))
    }
    @MainActor func testCopyAndCutPasteAtLatestEditCursorOnTopmostSelectedTrack() throws {
        for moving in [false, true] {
            var project = fixture()
            project.songs[0].tracks.append(Track(id: UUID(), name: "Third", role: .other))
            let executor = ClipboardExecutor()
            executor.transport.playing = true
            let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
            let original = project.songs[0].tracks[0].clips[0]
            let destination = project.songs[0].tracks[1].id, last = project.songs[0].tracks[2].id
            XCTAssertTrue(show.copyItems([original.id], moving: moving))
            show.setMixerTrackSelection([last, destination], anchor: last)
            show.send(.editSeek, value: 73.125)
            let pasted = show.pasteItems()
            let value = try XCTUnwrap(show.current?.tracks[1].clips.first { pasted.contains($0.id) })
            var expected = original; expected.id = value.id; expected.startTime = 73.125
            XCTAssertEqual(value, expected)
            XCTAssertEqual(show.current?.tracks[0].clips.count, moving ? 0 : 1)
            XCTAssertTrue(show.current?.tracks[2].clips.isEmpty == true)
            XCTAssertEqual(value.id == original.id, moving)
            XCTAssertTrue(show.snapshot.transport.playing)
            XCTAssertEqual(show.snapshot.transport.position, 7)
            XCTAssertTrue(show.cutGridItems.isEmpty)
            show.undo(); XCTAssertEqual(show.snapshot.project, project)
            show.redo(); XCTAssertEqual(show.current?.tracks[1].clips.last, expected)
            show.send(.stopAll)
        }
    }
    func testMultiTrackPasteTranslatesRowsAndPreservesGapsForCopyAndCut() throws {
        for moving in [false, true] {
            var project = fixture()
            project.songs[0].tracks.insert(Track(id: UUID(), name: "Gap", role: .other), at: 1)
            project.songs[0].tracks.append(Track(id: UUID(), name: "Fourth", role: .other))
            let ids = Set(project.songs[0].tracks.flatMap(\.clips).map(\.id))
            let clipboard = try XCTUnwrap(GridItemClipboard(project: project, song: project.songs[0].id, selected: ids, moving: moving))
            let tracks = project.songs[0].tracks
            let entries = try clipboard.items(in: project, at: 51.75, selectedTracks: [tracks[1].id, tracks[3].id])
            XCTAssertEqual(entries.map(\.track), [tracks[1].id, tracks[3].id])
            XCTAssertEqual(entries.map { $0.clip.startTime }, [51.75, 61.75])
            try project.pasteItems(entries, song: clipboard.song, moving: moving)
            XCTAssertEqual(project.songs[0].tracks.map { $0.clips.count }, moving ? [0, 1, 0, 1] : [1, 1, 1, 1])
        }
    }
    @MainActor func testFailedCrossTrackCutKeepsOriginalAndPendingCut() throws {
        var project = fixture()
        let special = Track(id: UUID(), name: "Program Change", role: TrackRole(rawValue: "programChange"))
        project.songs[0].tracks.append(special)
        let show = try ShowController(executor: ClipboardExecutor(), persistence: MemoryProjectStore(), initialProject: project)
        let original = project.songs[0].tracks[0].clips[0]
        XCTAssertTrue(show.copyItems([original.id], moving: true))
        XCTAssertTrue(show.pasteItems(selectedTracks: [special.id]).isEmpty)
        XCTAssertEqual(show.snapshot.project, project)
        XCTAssertEqual(show.cutGridItems, [original.id])
        XCTAssertEqual(show.pasteItems(selectedTracks: [project.songs[0].tracks[1].id]), [original.id])
    }
    @MainActor func testDuplicateAppendsAfterSelectionAndKeepsClipboard() throws {
        let executor = ClipboardExecutor(), project = fixture()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        let first = project.songs[0].tracks[0].clips[0], second = project.songs[0].tracks[1].clips[0]
        XCTAssertTrue(show.copyItems([first.id]))
        let duplicated = show.duplicateItems([first.id, second.id])
        XCTAssertEqual(duplicated.count, 2)
        let items = try XCTUnwrap(show.current).tracks.flatMap(\.clips).filter { duplicated.contains($0.id) }
        XCTAssertEqual(items.map(\.startTime), [25,35])
        var expected = first; expected.id = items[0].id; expected.startTime = 25
        XCTAssertEqual(items[0], expected)
        let pasted = show.pasteItems()
        XCTAssertEqual(pasted.count, 1, "Duplicate must preserve the previous clipboard")
        XCTAssertEqual(show.current?.tracks[0].clips.last?.startTime, 100)
    }
    private func fixture() -> Project {
        var project = Project.empty(name: "Clipboard")
        var fx = NativeFXSettings(); fx.inserted = ["EQ", "Compressor"]; fx.eqEnabled = true; fx.bands[1].gain = 5
        var first = Track(id: UUID(), name: "First", role: .keys)
        first.clips = [AudioClip(id: UUID(), name: "Stem", startTime: 10, duration: 5, sourceOffset: 1,
            waveform: [0.1, 0.3], audioFile: AudioFile(path: "Stems/original.wav"), gain: 0.5,
            waveformChannels: [[0.1, 0.3], [0.2, 0.4]], muted: true, playbackRate: 1.2, loopStart: 1, loopLength: 3, fx: fx, fxBypassed: true)]
        var second = Track(id: UUID(), name: "Second", role: .bass)
        second.clips = [AudioClip(id: UUID(), name: "Other", startTime: 20, duration: 5, audioFile: AudioFile(path: "Stems/other.wav"))]
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
        XCTAssertEqual(project.mediaPaths, ["Stems/original.wav", "Stems/other.wav"])
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
    func testFailedProjectionMediaMoveIsAtomicAndRemainsAvailableToPasteElsewhere() throws {
        var project = Project.empty(name: "Text")
        var track = Track(id: UUID(), name: "Teleprompter", role: TrackRole(rawValue: "teleprompt"))
        track.clips = [AudioClip(id: UUID(), name: "One", startTime: 0, duration: 10, audioFile: AudioFile(path: "Videos/one.mp4")), AudioClip(id: UUID(), name: "Two", startTime: 20, duration: 10, audioFile: AudioFile(path: "Videos/two.mp4"))]
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
        XCTAssertEqual(show.cutGridItems, [original.id])
        XCTAssertEqual(show.snapshot.project, project); XCTAssertFalse(show.hasUnsavedChanges)
        let ids = show.pasteItems()
        XCTAssertEqual(ids, [original.id])
        XCTAssertTrue(show.cutGridItems.isEmpty)
        XCTAssertEqual(show.current?.tracks[0].clips[0].startTime, 100, "paste follows editPosition, independently of playback position")
        XCTAssertEqual(executor.loads, 1); XCTAssertEqual(executor.reads, reads); XCTAssertEqual(executor.pastes, 1)
        show.undo(); XCTAssertEqual(show.snapshot.project, project)
        show.redo(); XCTAssertEqual(show.current?.tracks[0].clips[0].startTime, 100)
        let copies = show.pasteItems()
        XCTAssertEqual(copies.count, 1); XCTAssertFalse(copies.contains(original.id), "the completed move becomes a reusable copy")
    }
    @MainActor func testCancelCutAndReplacingItWithCopyLeaveArrangementIntact() throws {
        let project = fixture(), executor = ClipboardExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        let ids = Set(project.songs[0].tracks.flatMap(\.clips).map(\.id))
        XCTAssertTrue(show.copyItems(ids, moving: true))
        XCTAssertEqual(show.cutGridItems, ids)
        show.cancelGridCut()
        XCTAssertTrue(show.cutGridItems.isEmpty)
        XCTAssertTrue(show.pasteItems().isEmpty)
        XCTAssertEqual(show.snapshot.project, project)
        XCTAssertTrue(show.copyItems(ids, moving: true))
        XCTAssertTrue(show.copyItems(ids))
        XCTAssertTrue(show.cutGridItems.isEmpty)
        XCTAssertEqual(show.snapshot.project, project)
        XCTAssertFalse(show.hasUnsavedChanges)
    }

}
