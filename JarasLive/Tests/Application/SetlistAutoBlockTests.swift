import XCTest
@testable import JarasApplication

@MainActor private final class AutoBlockExecutor: CommandExecutor {
    var project = Project.empty(name: "Auto block")
    var transport = TransportState(playing: false, position: 0, queue: QueueState(),
                                   loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0))
    var loadCount = 0
    var snapshotCount = 0
    var projectEditCount = 0
    var setlistWrites = 0
    var rejectsSetlist = false
    var commands: [ShowCommand] = []

    func load(_ project: Project) throws {
        self.project = project
        loadCount += 1
        transport.songId = project.songs.first?.id
        transport.playing = false; transport.subPlay.playing = false
        transport.position = 0; transport.editPosition = 0
    }
    func snapshot() throws -> ShowSnapshot {
        snapshotCount += 1
        return ShowSnapshot(project: project, transport: transport)
    }
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: transport) }
    func configureRegionSetlist(_ state: RegionSetlist) throws {
        if rejectsSetlist { throw ProjectError.invalid("Setlist update rejected") }
        project.regionSetlist = state
        setlistWrites += 1
    }
    func applyProjectEdit(_ project: Project) throws { self.project = project; projectEditCount += 1 }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws {
        commands.append(command)
        switch command {
        case .selectRegion:
            guard let region = project.songs.first?.parts.first(where: { $0.id == target }) else { return }
            transport.regionId = region.id; transport.position = region.startTime; transport.editPosition = region.startTime
        case .queueRegion:
            // Model manual queue gestures only; automatic block boundaries are exercised by Core tests.
            if transport.queuedRegionId == target {
                transport.queuedRegionId = nil
                project.regionSetlist?.autoAdvance = false
            } else { transport.queuedRegionId = target }
        case .play: transport.playing = true
        case .stop, .stopAll: transport.playing = false; transport.subPlay.playing = false
        default: break
        }
    }
    func addTrack(id: UUID, name: String, role: TrackRole) throws {}
    func advance(_ elapsed: Double) {}
    func finishCurrentSong(_ enabled: Bool) {}
}

final class SetlistAutoBlockTests: XCTestCase {
    private func fixture() -> Project {
        var project = Project.empty(name: "Block preference")
        project.songs[0].duration = 40
        project.songs[0].parts = [Part(id: UUID(), name: "Opening", startTime: 0, endTime: 10),
                                  Part(id: UUID(), name: "Encore", startTime: 20, endTime: 30)]
        project.regionSetlist = RegionSetlist()
        return project
    }

    func testLegacySetlistWithoutSettingDecodesAsDisabledAndRoundTrips() throws {
        let legacy = Data(#"{"playlists":[],"autoAdvance":true}"#.utf8)
        let state = try JSONDecoder().decode(RegionSetlist.self, from: legacy)
        XCTAssertNil(state.autoUntilBlockEnd)
        XCTAssertFalse(state.autoUntilBlockEnd == true)
        XCTAssertTrue(state.autoAdvance, "A legacy project's existing Auto preference survives decoding")

        var project = fixture(); project.regionSetlist = state
        let restored = try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(project))
        XCTAssertNil(restored.regionSetlist?.autoUntilBlockEnd)
        XCTAssertTrue(restored.regionSetlist?.autoAdvance == true)
    }

    @MainActor func testPreferenceSurvivesSaveAndReopenAndBelongsToItsProject() async throws {
        let store = MemoryProjectStore()
        let show = try ShowController(executor: AutoBlockExecutor(), persistence: store, initialProject: fixture())
        show.setAutoUntilBlockEnd(true)
        try await show.flushProject()
        let stored = await store.load()
        let saved = try XCTUnwrap(stored)
        let restored = try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(saved))
        let reopened = try ShowController(executor: AutoBlockExecutor(), persistence: store, initialProject: restored)
        XCTAssertEqual(reopened.regionSetlist.autoUntilBlockEnd, true)
        XCTAssertFalse(reopened.regionSetlist.autoAdvance, "The block preference does not enable Auto by itself")

        reopened.setAutoUntilBlockEnd(false)
        try await reopened.flushProject()
        let disabled = await store.load()
        let savedDisabled = try XCTUnwrap(disabled)
        let disabledRoundTrip = try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(savedDisabled))
        XCTAssertEqual(disabledRoundTrip.regionSetlist?.autoUntilBlockEnd, false)

        try reopened.replaceProject(restored)
        XCTAssertEqual(reopened.regionSetlist.autoUntilBlockEnd, true)
        try reopened.replaceProject(fixture())
        XCTAssertNil(reopened.regionSetlist.autoUntilBlockEnd, "A different project keeps its own default")
    }

    @MainActor func testSettingPublishesSetlistWithoutReloadingAudioOrChangingPlayback() throws {
        let executor = AutoBlockExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: fixture())
        let first = try XCTUnwrap(show.current?.parts.first)
        show.focusRegion(first.id); show.send(.play)
        defer { show.send(.stopAll) }
        let before = show.snapshot.transport
        let revision = show.projectRevision, setlistRevision = show.setlistRevision
        let loads = executor.loadCount, snapshots = executor.snapshotCount, commands = executor.commands
        var setlistUpdates = 0, projectUpdates = 0, audioUpdates = 0
        show.onSetlistEdited = { setlistUpdates += 1 }
        show.onProjectEdited = { projectUpdates += 1 }
        show.audioUpdate = { _, _ in audioUpdates += 1 }

        show.setAutoUntilBlockEnd(true)
        XCTAssertEqual(show.regionSetlist.autoUntilBlockEnd, true)
        XCTAssertEqual(executor.project.regionSetlist?.autoUntilBlockEnd, true)
        XCTAssertEqual(executor.setlistWrites, 1)
        XCTAssertEqual(show.setlistRevision, setlistRevision + 1)
        XCTAssertEqual(setlistUpdates, 1)
        XCTAssertTrue(show.hasUnsavedChanges)
        XCTAssertEqual(show.snapshot.transport, before)

        show.setAutoUntilBlockEnd(false)
        XCTAssertEqual(show.regionSetlist.autoUntilBlockEnd, false)
        XCTAssertEqual(executor.project.regionSetlist?.autoUntilBlockEnd, false)
        XCTAssertEqual(executor.setlistWrites, 2)
        XCTAssertEqual(show.setlistRevision, setlistRevision + 2)
        XCTAssertEqual(setlistUpdates, 2)
        XCTAssertEqual(show.projectRevision, revision)
        XCTAssertEqual(projectUpdates, 0)
        XCTAssertEqual(audioUpdates, 0)
        XCTAssertEqual(executor.projectEditCount, 0)
        XCTAssertEqual(executor.loadCount, loads)
        XCTAssertEqual(executor.snapshotCount, snapshots)
        XCTAssertEqual(executor.commands, commands)
        XCTAssertEqual(show.snapshot.transport, before)
    }

    @MainActor func testManualSelectionQueueAndCancellationPreserveBlockPreference() throws {
        var project = fixture()
        project.regionSetlist?.autoUntilBlockEnd = true
        project.regionSetlist?.autoAdvance = true
        let first = project.songs[0].parts[0], second = project.songs[0].parts[1]
        let executor = AutoBlockExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        defer { show.send(.stopAll) }

        show.focusRegion(first.id)
        XCTAssertEqual(executor.commands.last, .selectRegion)
        XCTAssertEqual(show.regionSetlist.autoUntilBlockEnd, true)
        show.send(.play)
        show.focusRegion(second.id)
        XCTAssertEqual(executor.commands.last, .queueRegion)
        XCTAssertEqual(show.snapshot.transport.queuedRegionId, second.id)
        XCTAssertEqual(show.regionSetlist.autoUntilBlockEnd, true)

        show.focusRegion(second.id)
        XCTAssertNil(show.snapshot.transport.queuedRegionId)
        XCTAssertFalse(show.regionSetlist.autoAdvance, "Cancelling the queue still disables Auto")
        XCTAssertEqual(show.regionSetlist.autoUntilBlockEnd, true, "The separate block preference survives queue cancellation")
        XCTAssertEqual(executor.project.regionSetlist?.autoUntilBlockEnd, true)
        show.focusRegion(second.id)
        XCTAssertEqual(show.snapshot.transport.queuedRegionId, second.id)
        XCTAssertEqual(show.regionSetlist.autoUntilBlockEnd, true)
    }

    @MainActor func testRejectedSettingPreservesExistingPreferenceAndRevisions() throws {
        let executor = AutoBlockExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: fixture())
        let revision = show.projectRevision, setlistRevision = show.setlistRevision
        executor.rejectsSetlist = true

        show.setAutoUntilBlockEnd(true)

        XCTAssertNil(show.regionSetlist.autoUntilBlockEnd)
        XCTAssertNil(executor.project.regionSetlist?.autoUntilBlockEnd)
        XCTAssertEqual(show.projectRevision, revision)
        XCTAssertEqual(show.setlistRevision, setlistRevision)
        XCTAssertEqual(executor.setlistWrites, 0)
        XCTAssertFalse(show.hasUnsavedChanges)
        XCTAssertTrue(show.message.contains("Setlist update rejected"))
    }
}
