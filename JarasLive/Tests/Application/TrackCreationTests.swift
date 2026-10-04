import XCTest
@testable import JarasApplication

@MainActor private final class BulkTrackExecutor: CommandExecutor {
    var project = Project.empty(name: "Creation")
    var editCount = 0
    var rejectEdits = false
    func load(_ project: Project) throws { self.project = project }
    func snapshot() throws -> ShowSnapshot {
        ShowSnapshot(project: project, transport: TransportState(playing: false, songId: project.songs.first?.id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    }
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: try snapshot().transport) }
    func applyProjectEdit(_ value: Project) throws {
        if rejectEdits { throw ProjectError.invalid("Edit rejected") }
        try value.validate(); project = value; editCount += 1
    }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws {}
    func addTrack(id: UUID, name: String, role: TrackRole) throws { XCTFail("Bulk creation must not submit one command per track") }
    func advance(_ elapsed: Double) {}
    func finishCurrentSong(_ enabled: Bool) {}
}

final class TrackCreationTests: XCTestCase {
    @MainActor func testNewStandardColorPreservesExistingAndSpecialTracks() throws {
        var project = Project.empty(name: "Colors")
        let legacy = Track(id: UUID(), name: "Legacy", role: .guide)
        let custom = Track(id: UUID(), name: "Custom", role: .other, color: 0x45aaff)
        project.songs[0].tracks = [legacy, custom]
        let restored = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        XCTAssertNil(restored.songs[0].tracks[0].color)
        XCTAssertEqual(restored.songs[0].tracks[1].color, custom.color)
        let show = try ShowController(executor: BulkTrackExecutor(), persistence: MemoryProjectStore(), initialProject: restored)
        let standard = try XCTUnwrap(show.addTracks(name: "New", role: .guide, count: 1).first)
        let video = try XCTUnwrap(show.addTracks(name: "Video", role: TrackRole(rawValue: "video"), count: 1).first)
        XCTAssertEqual(show.current?.tracks.first { $0.id == standard }?.color, 0x828282)
        XCTAssertNil(show.current?.tracks.first { $0.id == video }?.color)
        XCTAssertNil(show.current?.tracks.first { $0.id == legacy.id }?.color)
        XCTAssertEqual(show.current?.tracks.first { $0.id == custom.id }?.color, custom.color)
    }
    @MainActor func testDroppingItemBelowLastTrackCreatesOneTrackAndUndoRestoresBoth() throws {
        var project = Project.empty(name: "Drag")
        var source = Track(id: UUID(), name: "Source", role: .other)
        let clip = AudioClip(id: UUID(), name: "Voice", startTime: 2, duration: 5, gain: 0.4, muted: true)
        source.clips = [clip]
        project.songs[0].tracks = [source]
        let executor = BulkTrackExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        let pending = Track(id: UUID(), name: "Track 2", role: .other)
        XCTAssertEqual(show.current?.tracks.count, 1, "The drag preview must not edit the project")
        show.moveClipToNewStandardTrack(clip.id, start: 12, newTrack: pending)
        XCTAssertEqual(executor.editCount, 1)
        XCTAssertEqual(show.current?.tracks.count, 2)
        XCTAssertEqual(show.current?.tracks[0].clips.count, 0)
        XCTAssertEqual(show.current?.tracks[1].id, pending.id)
        XCTAssertEqual(show.current?.tracks[1].color, Track.defaultStandardColor)
        XCTAssertEqual(show.current?.tracks[1].clips.first?.startTime, 12)
        XCTAssertEqual(show.current?.tracks[1].clips.first?.gain, 0.4)
        XCTAssertEqual(show.current?.tracks[1].clips.first?.muted, true)
        show.undo()
        XCTAssertEqual(show.current?.tracks.count, 1)
        XCTAssertEqual(show.current?.tracks[0].clips, [clip])
        show.redo()
        XCTAssertEqual(show.current?.tracks.count, 2)
        XCTAssertEqual(show.current?.tracks[1].clips.first?.id, clip.id)
    }
    @MainActor func testBulkCreationIsOneEditWithSequentialMonoInputsAndOneUndo() throws {
        let executor = BulkTrackExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: .empty(name: "Bulk"))
        let inputs = ShowController.sequentialInputPatches(count: 5, channels: 2)
        var updates = 0
        show.audioUpdate = { _, _ in updates += 1 }
        let ids = show.addTracks(name: "  Drums  ", role: .other, count: 5, inputPatches: inputs)
        XCTAssertEqual(ids.count, 5)
        XCTAssertEqual(executor.editCount, 1)
        XCTAssertEqual(updates, 1)
        XCTAssertEqual(show.current?.tracks.map(\.name), ["Drums 01", "Drums 02", "Drums 03", "Drums 04", "Drums 05"])
        XCTAssertTrue(show.current?.tracks.allSatisfy { $0.color == Track.defaultStandardColor } == true)
        XCTAssertEqual(show.current?.tracks.compactMap(\.inputPatch).map(\.firstChannel), [1, 2, 1, 2, 1])
        XCTAssertTrue(inputs.allSatisfy { $0.channelCount == 1 })
        show.undo()
        XCTAssertEqual(show.current?.tracks.count, 0)
        show.redo()
        XCTAssertEqual(show.current?.tracks.map(\.id), ids)
        XCTAssertEqual(show.current?.tracks.compactMap(\.inputPatch), inputs)
    }
    @MainActor func testCreationBeyondOneThousandTracksPersists() throws {
        var project = Project.empty(name: "Large project")
        project.songs[0].tracks = (0..<1000).map { Track(id: UUID(), name: "Track \($0)", role: .other) }
        let executor = BulkTrackExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        XCTAssertEqual(show.addTracks(name: "Additional", role: .other, count: 25).count, 25)
        XCTAssertEqual(show.current?.tracks.count, 1025)
        try show.snapshot.project.validate()
        let restored = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(show.snapshot.project))
        XCTAssertEqual(restored.songs[0].tracks.count, 1025)
        XCTAssertTrue(show.addTracks(name: "Invalid", role: .other, count: 0).isEmpty)
    }
    @MainActor func testCreatingAfterGroupChildKeepsTheNewTracksInsideGroup() throws {
        var project = Project.empty(name: "Group")
        let folder = Track(id: UUID(), name: "Group", role: .other)
        var child = Track(id: UUID(), name: "Existing", role: .other); child.parentTrackID = folder.id
        let next = Track(id: UUID(), name: "Outside", role: .other)
        project.songs[0].tracks = [folder, child, next]
        let show = try ShowController(executor: BulkTrackExecutor(), persistence: MemoryProjectStore(), initialProject: project)
        let ids = show.addTracks(name: "New", role: .other, count: 2, after: child.id)
        XCTAssertEqual(show.current?.tracks.map(\.id), [folder.id, child.id] + ids + [next.id])
        let inserted = try XCTUnwrap(show.current?.tracks.filter { ids.contains($0.id) })
        XCTAssertEqual(inserted.map(\.parentTrackID), [folder.id, folder.id])
        XCTAssertTrue(inserted.allSatisfy { $0.primaryOutput == .masterGroup })
        try show.snapshot.project.validate()
    }
    @MainActor func testSpecialTracksStayAtTopWithoutSplittingGroupsAndTimecodeIsUnique() throws {
        var project = Project.empty(name: "Special")
        let folder = Track(id: UUID(), name: "Folder", role: .other)
        var child = Track(id: UUID(), name: "Child", role: .other); child.parentTrackID = folder.id
        project.songs[0].tracks = [folder, child]
        let show = try ShowController(executor: BulkTrackExecutor(), persistence: MemoryProjectStore(), initialProject: project)
        XCTAssertEqual(show.addTracks(name: "Ignored", role: TrackRole(rawValue: "video"), count: 1, after: folder.id).count, 1)
        XCTAssertEqual(show.addTracks(name: "Ignored", role: TrackRole(rawValue: "teleprompt"), count: 1, after: child.id).count, 1)
        XCTAssertEqual(show.addTracks(name: "Ignored", role: TrackRole(rawValue: "teleprompt2"), count: 1, after: child.id).count, 1)
        XCTAssertEqual(show.addTracks(name: "Ignored", role: TrackRole(rawValue: "timecode"), count: 1, after: child.id).count, 1)
        XCTAssertEqual(show.addTracks(name: "Ignored", role: .chords, count: 1, after: child.id).count, 1)
        XCTAssertEqual(show.current?.tracks.map(\.name), ["Timecode", "Chords", "Teleprompter 1", "Teleprompter 2", "Video", "Folder", "Child"])
        XCTAssertEqual(show.current?.tracks[0].patch, OutputPatch.none)
        XCTAssertNotNil(show.current?.tracks[0].timecode)
        XCTAssertTrue(show.addTracks(name: "Timecode", role: TrackRole(rawValue: "timecode"), count: 1).isEmpty)
        XCTAssertTrue(show.addTracks(name: "Video", role: TrackRole(rawValue: "video"), count: 2).isEmpty)
        let editsBeforeDuplicates = (show.current?.tracks.count ?? 0)
        for kind: TrackKind in [.timecode, .chords, .teleprompt, .teleprompt2, .video] {
            XCTAssertTrue(show.addTracks(name: kind.title, role: TrackRole(rawValue: kind.rawValue), count: 1).isEmpty, "Duplicated \(kind.title)")
            XCTAssertEqual(show.message, "A \(kind.title) track already exists.")
            XCTAssertNil(show.addTrack(name: kind.title, role: TrackRole(rawValue: kind.rawValue)), "Legacy creation also rejects duplicated \(kind.title)")
        }
        XCTAssertEqual(show.current?.tracks.count, editsBeforeDuplicates)
        try show.snapshot.project.validate()
    }
    @MainActor func testSequentialRoutingDoesNotInventInputsAndRejectedEditKeepsSnapshot() throws {
        XCTAssertEqual(ShowController.sequentialInputPatches(count: 4, channels: 0), [])
        XCTAssertEqual(ShowController.sequentialInputPatches(count: 3, channels: 1).map(\.firstChannel), [1, 1, 1])
        let executor = BulkTrackExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: .empty(name: "Failure"))
        executor.rejectEdits = true
        XCTAssertTrue(show.addTracks(name: "Track", role: .other, count: 5).isEmpty)
        XCTAssertEqual(show.current?.tracks.count, 0)
        XCTAssertFalse(show.hasUnsavedChanges)
        XCTAssertFalse(show.canUndo)
    }
}
