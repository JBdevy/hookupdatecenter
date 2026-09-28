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
        XCTAssertEqual(show.current?.tracks.compactMap(\.inputPatch).map(\.firstChannel), [1, 2, 1, 2, 1])
        XCTAssertTrue(inputs.allSatisfy { $0.channelCount == 1 })
        show.undo()
        XCTAssertEqual(show.current?.tracks.count, 0)
        show.redo()
        XCTAssertEqual(show.current?.tracks.map(\.id), ids)
        XCTAssertEqual(show.current?.tracks.compactMap(\.inputPatch), inputs)
    }
    @MainActor func testCreationRespectsProjectWideLimitAndDoesNotPartiallyInsert() throws {
        var project = Project.empty(name: "Limit")
        project.songs[0].tracks = (0..<399).map { Track(id: UUID(), name: "Track \($0)", role: .other) }
        let executor = BulkTrackExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        XCTAssertTrue(show.addTracks(name: "Over limit", role: .other, count: 2).isEmpty)
        XCTAssertEqual(executor.editCount, 0)
        XCTAssertEqual(show.current?.tracks.count, 399)
        XCTAssertEqual(show.addTracks(name: "Last", role: .other, count: 1).count, 1)
        XCTAssertEqual(show.current?.tracks.count, 400)
        XCTAssertTrue(show.addTracks(name: "Beyond", role: .other, count: 1).isEmpty)
        XCTAssertEqual(executor.editCount, 1)
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
        XCTAssertEqual(show.addTracks(name: "Ignored", role: TrackRole(rawValue: "timecode"), count: 1, after: child.id).count, 1)
        XCTAssertEqual(show.addTracks(name: "Ignored", role: .chords, count: 1, after: child.id).count, 1)
        XCTAssertEqual(show.current?.tracks.map(\.name), ["Timecode", "Chords", "Teleprompter", "Video", "Folder", "Child"])
        XCTAssertEqual(show.current?.tracks[0].patch, OutputPatch.none)
        XCTAssertNotNil(show.current?.tracks[0].timecode)
        XCTAssertTrue(show.addTracks(name: "Timecode", role: TrackRole(rawValue: "timecode"), count: 1).isEmpty)
        XCTAssertTrue(show.addTracks(name: "Video", role: TrackRole(rawValue: "video"), count: 2).isEmpty)
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
