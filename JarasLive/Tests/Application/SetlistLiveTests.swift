import XCTest
@testable import JarasApplication

@MainActor private final class LiveExecutor: CommandExecutor {
    var project = Project.empty(name: "Live")
    var transport = TransportState(playing: false, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0))
    var setlistWrites = 0
    func load(_ project: Project) throws {
        self.project = project
        transport.songId = project.songs.first?.id
        transport.playing = false; transport.subPlay.playing = false
        transport.position = 0; transport.editPosition = 0
    }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws {
        switch command {
        case .play: transport.playing = true; transport.paused = false
        case .pause: transport.playing = false; transport.paused = true
        case .stop, .stopAll: transport.playing = false; transport.subPlay.playing = false; transport.paused = false
        case .seek: transport.position = value
        case .editSeek: transport.editPosition = value; if !transport.playing { transport.position = value }
        case .subSeek: transport.subPlay.position = value
        case .subPlay: transport.subPlay.playing = true
        case .subStop: transport.subPlay.playing = false
        default: break
        }
        transport.regionId = project.songs.first?.sectionRegion(at: transport.position)?.id
    }
    func snapshot() throws -> ShowSnapshot { ShowSnapshot(project: project, transport: transport) }
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: transport) }
    func configureRegionSetlist(_ state: RegionSetlist) throws { project.regionSetlist = state; setlistWrites += 1 }
    func applyProjectEdit(_ project: Project) throws { self.project = project }
    func advance(_ elapsed: Double) {
        if transport.playing { transport.position += elapsed }
        if transport.subPlay.playing { transport.subPlay.position += elapsed }
    }
    func finishCurrentSong(_ enabled: Bool) {}
    func addTrack(id: UUID, name: String, role: TrackRole) throws {}
}

final class SetlistLiveTests: XCTestCase {
    private func project() -> Project {
        var project = Project.empty(name: "Live history")
        project.songs[0].duration = 500
        project.songs[0].parts = [Part(id: UUID(), name: "First", startTime: 0, endTime: 200),
                                  Part(id: UUID(), name: "Second", startTime: 200, endTime: 400)]
        return project
    }

    @MainActor func testThresholdUsesRealPlaybackAndPublishesOnlyAtTenSeconds() throws {
        let project = project(), executor = LiveExecutor()
        var now = 0.0
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project, playbackClock: { now })
        defer { show.send(.stopAll) }
        XCTAssertFalse(show.setlistLiveEnabled)
        show.send(.play)
        now = 20; show.tick()
        XCTAssertTrue(show.playedLiveRegionIDs.isEmpty, "Disabled Live never counts playback")
        show.toggleSetlistLive()
        let revision = show.projectRevision, setlistRevision = show.setlistRevision
        for _ in 0..<99 { now += 0.1; show.tick() }
        XCTAssertTrue(show.playedLiveRegionIDs.isEmpty)
        XCTAssertEqual(executor.setlistWrites, 1, "No per-frame project or history writes")
        XCTAssertEqual(show.setlistRevision, setlistRevision)
        now += 0.1; show.tick()
        XCTAssertEqual(show.playedLiveRegionIDs, [project.songs[0].parts[0].id])
        XCTAssertEqual(show.setlistRevision, setlistRevision + 1)
        XCTAssertEqual(show.projectRevision, revision, "Marking a played song must not rebuild the grid/audio graph")
        now += 20; show.tick()
        XCTAssertEqual(executor.setlistWrites, 2, "Already marked songs do not keep publishing")
    }

    @MainActor func testPauseStopAndSeeksCannotInventPlayedTime() throws {
        let project = project(), executor = LiveExecutor()
        var now = 0.0
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project, playbackClock: { now })
        defer { show.send(.stopAll) }
        show.toggleSetlistLive(); show.send(.play)
        now += 4; show.tick()
        show.send(.seek, value: 130)
        XCTAssertTrue(show.playedLiveRegionIDs.isEmpty, "Seeking far into a song is not playing it")
        show.send(.pause)
        now += 200; show.tick()
        show.send(.editSeek, value: 150)
        XCTAssertTrue(show.playedLiveRegionIDs.isEmpty)
        show.send(.play)
        now += 5; show.send(.stop)
        XCTAssertTrue(show.playedLiveRegionIDs.isEmpty, "Final command interval counts, stopped time does not")
        now += 300; show.tick()
        show.send(.play)
        now += 1; show.tick()
        XCTAssertEqual(show.playedLiveRegionIDs, [project.songs[0].parts[0].id])
    }

    @MainActor func testDisablingLiveClearsMarksAndPartialCounts() throws {
        let project = project(), executor = LiveExecutor()
        var now = 0.0
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project, playbackClock: { now })
        defer { show.send(.stopAll) }
        show.toggleSetlistLive(); show.send(.play)
        now += 6; show.tick(); show.toggleSetlistLive()
        now += 50; show.tick(); show.toggleSetlistLive()
        now += 4; show.tick()
        let first = project.songs[0].parts[0].id
        XCTAssertTrue(show.playedLiveRegionIDs.isEmpty, "Re-enabling cannot reuse the previous six seconds")
        now += 6; show.tick()
        XCTAssertEqual(show.playedLiveRegionIDs, [first])
        let revision = show.setlistRevision
        let projectRevision = show.projectRevision
        show.toggleSetlistLive()
        XCTAssertFalse(show.setlistLiveEnabled)
        XCTAssertTrue(show.playedLiveRegionIDs.isEmpty)
        XCTAssertEqual(show.snapshot.project.regionSetlist?.playedLiveRegionIDs, [])
        XCTAssertEqual(executor.project.regionSetlist?.playedLiveRegionIDs, [])
        XCTAssertGreaterThan(show.setlistRevision, revision, "The reset must invalidate desktop and Remote presentation")
        XCTAssertEqual(show.projectRevision, projectRevision, "Resetting marks must not rebuild the audio graph")
        var another = project; another.id = UUID()
        try show.replaceProject(another)
        XCTAssertFalse(show.setlistLiveEnabled)
        XCTAssertTrue(show.playedLiveRegionIDs.isEmpty)
        show.toggleSetlistLive(); show.send(.play)
        now += 9; show.tick()
        XCTAssertTrue(show.playedLiveRegionIDs.isEmpty)
        try show.replaceProject(another) // Reopening the same project also resets partial stopwatch values.
        show.toggleSetlistLive(); show.send(.play)
        now += 1; show.tick()
        XCTAssertTrue(show.playedLiveRegionIDs.isEmpty)
    }

    @MainActor func testLiveMarksAndEnabledFlagSurviveSaveAndLoad() async throws {
        let project = project(), executor = LiveExecutor(), store = MemoryProjectStore()
        var now = 0.0
        let show = try ShowController(executor: executor, persistence: store, initialProject: project, playbackClock: { now })
        show.toggleSetlistLive(); show.send(.play)
        now += 10; show.tick(); show.send(.stopAll)
        try await show.flushProject()
        let stored = await store.load()
        let saved = try XCTUnwrap(stored)
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(saved))
        let reopened = try ShowController(executor: LiveExecutor(), persistence: MemoryProjectStore(), initialProject: decoded)
        XCTAssertTrue(reopened.setlistLiveEnabled)
        XCTAssertEqual(reopened.playedLiveRegionIDs, [project.songs[0].parts[0].id])
        show.toggleSetlistLive()
        try await show.flushProject()
        let cleared = await store.load()
        let clearedProject = try XCTUnwrap(cleared)
        let afterReset = try ShowController(executor: LiveExecutor(), persistence: MemoryProjectStore(), initialProject: clearedProject)
        XCTAssertFalse(afterReset.setlistLiveEnabled)
        XCTAssertTrue(afterReset.playedLiveRegionIDs.isEmpty, "Saving and reopening cannot bring cleared marks back")
    }

    func testSimultaneousHeadsDoNotDoubleCountAndSubplayPromotionKeepsTime() {
        let project = project(), song = project.songs[0], first = song.parts[0], second = song.parts[1]
        var tracker = SetlistLivePlaybackTracker()
        var before = TransportState(playing: true, songId: song.id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: true, position: 50))
        var after = before; after.position = 5; after.subPlay.position = 55
        XCTAssertTrue(tracker.record(project: project, revision: 0, before: before, after: after, elapsed: 5, marked: []).isEmpty)
        before = after; after.position += 5; after.subPlay.position += 5
        XCTAssertEqual(tracker.record(project: project, revision: 0, before: before, after: after, elapsed: 5, marked: []), [first.id])

        tracker = SetlistLivePlaybackTracker()
        before.position = 100; before.subPlay.position = 200
        after = before; after.position = 106; after.subPlay.position = 206
        XCTAssertTrue(tracker.record(project: project, revision: 0, before: before, after: after, elapsed: 6, marked: []).isEmpty)
        before = after; after.position = 210; after.subPlay.playing = false; after.subPlayPromotion = 1
        let marked = tracker.record(project: project, revision: 0, before: before, after: after, elapsed: 4, marked: [])
        XCTAssertTrue(marked.contains(second.id), "SubPlay's six seconds survive promotion into main playback")
    }

    func testCrossingRegionBoundaryAndStoppedTailOnlyCountTheirActualSpan() {
        var project = project(); project.songs[0].parts[0].endTime = 10
        project.songs[0].parts[1].startTime = 10; project.songs[0].parts[1].endTime = 40
        let song = project.songs[0], first = song.parts[0], second = song.parts[1]
        var tracker = SetlistLivePlaybackTracker()
        var before = TransportState(playing: true, songId: song.id, position: 5, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0))
        var after = before; after.position = 15
        XCTAssertTrue(tracker.record(project: project, revision: 0, before: before, after: after, elapsed: 10, marked: []).isEmpty)
        before = after; after.position = 20
        XCTAssertEqual(tracker.record(project: project, revision: 0, before: before, after: after, elapsed: 5, marked: []), [second.id])
        before.position = 8; after.position = 10; after.playing = false
        XCTAssertFalse(tracker.record(project: project, revision: 0, before: before, after: after, elapsed: 30, marked: [second.id]).contains(first.id), "An automatic stop cannot count the remaining wall time")
    }

    func testSingleDrawerSongCompletesParentAndLoopWrapCountsRealTime() {
        var project = project()
        let parent = project.songs[0].parts[0]
        let child = Part(id: UUID(), name: "Inside", startTime: 20, endTime: 50, parentRegionID: parent.id)
        project.songs[0].parts.append(child)
        var tracker = SetlistLivePlaybackTracker()
        let before = TransportState(playing: true, songId: project.songs[0].id, position: 30, queue: QueueState(), loop: LoopState(enabled: true, start: 30, end: 35), subPlay: SubPlayState(playing: false, position: 0))
        var after = before; after.position = 31
        XCTAssertEqual(tracker.record(project: project, revision: 0, before: before, after: after, elapsed: 11, marked: []), [parent.id, child.id])
    }

    private func unifiedProject() -> Project {
        var project = project()
        let parent = Part(id: UUID(), name: "Unified", startTime: 0, endTime: 100)
        let first = Part(id: UUID(), name: "Inside one", startTime: 0, endTime: 30, parentRegionID: parent.id)
        let second = Part(id: UUID(), name: "Inside two", startTime: 30, endTime: 60, parentRegionID: parent.id)
        project.songs[0].parts = [parent, first, second]
        return project
    }

    @MainActor func testUnifiedParentWaitsForEveryDrawerSongToReachTenSeconds() throws {
        let project = unifiedProject(), executor = LiveExecutor()
        let parent = project.songs[0].parts[0], first = project.songs[0].parts[1], second = project.songs[0].parts[2]
        var now = 0.0
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project, playbackClock: { now })
        defer { show.send(.stopAll) }
        show.toggleSetlistLive(); show.send(.play)
        let revision = show.projectRevision
        now += 10; show.tick()
        XCTAssertEqual(show.playedLiveRegionIDs, [first.id], "Playing the first song does not complete its wrapper")
        show.send(.seek, value: 30)
        now += 9; show.tick()
        XCTAssertEqual(show.playedLiveRegionIDs, [first.id], "The second song needs its own ten seconds")
        now += 1; show.tick()
        XCTAssertEqual(show.playedLiveRegionIDs, [parent.id, first.id, second.id])
        XCTAssertEqual(Set(show.snapshot.project.regionSetlist?.playedLiveRegionIDs ?? []), [parent.id, first.id, second.id])
        XCTAssertEqual(executor.setlistWrites, 3, "One toggle and one write per completed song, never per frame")
        XCTAssertEqual(show.projectRevision, revision, "Live completion does not rebuild the audio graph/grid")
        show.toggleSetlistLive()
        XCTAssertTrue(show.playedLiveRegionIDs.isEmpty, "Reset clears drawer children and their derived parent together")
        XCTAssertEqual(show.snapshot.project.regionSetlist?.playedLiveRegionIDs, [])
    }

    func testWrapperOnlyPlaybackAndEmptyDrawerDoNotCompleteAutomatically() {
        var project = unifiedProject()
        let song = project.songs[0], parent = song.parts[0]
        var tracker = SetlistLivePlaybackTracker()
        let before = TransportState(playing: true, songId: song.id, position: 70, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0))
        var after = before; after.position = 90
        XCTAssertTrue(tracker.record(project: project, revision: 0, before: before, after: after, elapsed: 20, marked: []).isEmpty,
                      "Time in the wrapper outside its songs does not complete the drawer")
        project.songs[0].parts = [parent]
        XCTAssertTrue(SetlistLivePlaybackTracker.normalizedMarks(project: project, marked: []).isEmpty,
                      "An empty children list must not satisfy completion automatically")
        after.position = 79
        XCTAssertTrue(tracker.record(project: project, revision: 1, before: before, after: after, elapsed: 9, marked: []).isEmpty)
        var continued = after; continued.position = 80
        XCTAssertEqual(tracker.record(project: project, revision: 1, before: after, after: continued, elapsed: 1, marked: []), [parent.id],
                       "With no children the model is an ordinary region and still requires ten seconds")
    }

    @MainActor func testPersistedPrematureParentDoesNotReplaceMissingChildHistory() throws {
        var project = unifiedProject()
        let parent = project.songs[0].parts[0], first = project.songs[0].parts[1], second = project.songs[0].parts[2]
        var state = RegionSetlist(); state.playedLiveRegionIDs = [parent.id, first.id]
        project.regionSetlist = state
        let show = try ShowController(executor: LiveExecutor(), persistence: MemoryProjectStore(), initialProject: project)
        XCTAssertFalse(show.setlistLiveEnabled)
        XCTAssertEqual(show.playedLiveRegionIDs, [first.id], "Old premature parent marks cannot imply children were played")
        project.regionSetlist?.playedLiveRegionIDs = [first.id, second.id]
        try show.replaceProject(project)
        XCTAssertEqual(show.playedLiveRegionIDs, [parent.id, first.id, second.id], "A complete persisted drawer derives its parent even with Live off")
        project.regionSetlist?.playedLiveRegionIDs = []
        try show.replaceProject(project)
        XCTAssertTrue(show.playedLiveRegionIDs.isEmpty, "Reset history clears both children and derived parent")
    }

    @MainActor func testAddingUnplayedSongToCompletedDrawerClearsOnlyParentMark() throws {
        var project = unifiedProject()
        let parent = project.songs[0].parts[0], first = project.songs[0].parts[1], second = project.songs[0].parts[2]
        let added = Part(id: UUID(), name: "New song", startTime: 90, endTime: 120)
        project.songs[0].parts.append(added)
        var state = RegionSetlist(); state.playedLiveRegionIDs = [parent.id, first.id, second.id]
        project.regionSetlist = state
        let show = try ShowController(executor: LiveExecutor(), persistence: MemoryProjectStore(), initialProject: project)
        XCTAssertEqual(show.playedLiveRegionIDs, [parent.id, first.id, second.id])
        XCTAssertTrue(show.unifyRegions(containing: parent.id, name: ""))
        XCTAssertEqual(show.snapshot.project.songs[0].parts.first { $0.id == added.id }?.parentRegionID, parent.id)
        XCTAssertEqual(show.playedLiveRegionIDs, [first.id, second.id], "Structural changes re-evaluate the parent while preserving completed songs")
    }
}
