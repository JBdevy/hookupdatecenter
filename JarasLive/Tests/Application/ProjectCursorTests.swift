import XCTest
@testable import JarasApplication

@MainActor private final class CursorExecutor: CommandExecutor {
    var project = Project.empty(name: "Cursor")
    var transport = TransportState(playing: false, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0))
    func load(_ project: Project) throws {
        self.project = project
        transport.playing = false; transport.subPlay.playing = false
        transport.songId = project.songs.first?.id; transport.position = 0; transport.editPosition = 0
    }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws {
        switch command {
        case .editSeek: transport.editPosition = value; if !transport.playing { transport.position = value }
        case .select: transport.songId = target
        case .play: transport.playing = true
        case .stop, .stopAll: transport.playing = false
        default: break
        }
    }
    func addTrack(id: UUID, name: String, role: TrackRole) throws {}
    func snapshot() throws -> ShowSnapshot { ShowSnapshot(project: project, transport: transport) }
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: transport) }
    func advance(_ elapsed: Double) { transport.position += elapsed }
    func finishCurrentSong(_ enabled: Bool) {}
}

final class ProjectCursorTests: XCTestCase {
    @MainActor func testSpecialSelectionUsesFirstChildPitchAndPlaybackUsesCurrentChild() throws {
        var project = Project.empty(name: "Pitch display")
        let group = Part(id: UUID(), name: "Special", startTime: 0, endTime: 30)
        let first = Part(id: UUID(), name: "First", startTime: 0, endTime: 20, parentRegionID: group.id, pitchSemitones: 4)
        let last = Part(id: UUID(), name: "Last", startTime: 15, endTime: 30, parentRegionID: group.id, pitchSemitones: -2)
        project.songs[0].parts = [group, last, first]
        let executor = CursorExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        show.focusRegion(group.id)
        XCTAssertEqual(show.pitchRegion?.id, first.id); XCTAssertEqual(show.pitchRegion?.semitones, 4)
        show.focusRegion(last.id)
        XCTAssertEqual(show.pitchRegion?.semitones, -2)
        executor.transport.playing = true; executor.transport.position = 18; executor.transport.regionId = group.id
        show.send(.ignoreNext)
        XCTAssertEqual(show.pitchRegion?.id, last.id)
    }

    @MainActor func testStopPublishesOnlyFinalAudioState() throws {
        let executor = CursorExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: .empty(name: "Transport"))
        var renderedStates: [Bool] = []
        show.audioUpdate = { snapshot, _ in renderedStates.append(snapshot.transport.playing) }
        show.send(.play)
        XCTAssertEqual(renderedStates, [true])
        renderedStates.removeAll()
        show.send(.stop)
        XCTAssertEqual(renderedStates, [false], "Stop must not schedule a redundant playing update before stopping")
        XCTAssertFalse(show.isPlaying)
    }

    @MainActor func testReopeningRemembersEditingCursorWithoutSavingOrAutoplay() throws {
        let suite = "jaras-test-cursor-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let project = Project.empty(name: "One")
        let executor = CursorExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project, cursorMemory: ProjectCursorMemory(preferences: defaults))
        show.send(.editSeek, value: 42.125)
        XCTAssertFalse(show.hasUnsavedChanges, "navigation is local workspace state")
        show.send(.play)
        executor.advance(12)
        show.tick()
        show.send(.stop)
        let reopened = try ShowController(executor: CursorExecutor(), persistence: MemoryProjectStore(), initialProject: project, cursorMemory: ProjectCursorMemory(preferences: defaults))
        XCTAssertEqual(reopened.snapshot.transport.editPosition, 42.125)
        XCTAssertEqual(reopened.snapshot.transport.position, 42.125)
        XCTAssertEqual(reopened.restoredCursorPosition, 42.125)
        XCTAssertFalse(reopened.isPlaying)
        let other = Project.empty(name: "Two")
        try reopened.replaceProject(other)
        XCTAssertEqual(reopened.snapshot.transport.position, 0)
        reopened.send(.editSeek, value: 17)
        try reopened.replaceProject(project)
        XCTAssertEqual(reopened.snapshot.transport.position, 42.125)
        try reopened.replaceProject(other)
        XCTAssertEqual(reopened.snapshot.transport.position, 17)
    }
    @MainActor func testSavedCursorClampsToProjectEndAndIgnoresInvalidPosition() throws {
        let suite = "jaras-test-cursor-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = ProjectCursorMemory(preferences: defaults)
        let project = Project.empty(name: "Shortened")
        memory.remember(project: project.id, songID: project.songs[0].id, position: project.songs[0].duration + 90)
        memory.remember(project: project.id, songID: project.songs[0].id, position: .nan)
        let show = try ShowController(executor: CursorExecutor(), persistence: MemoryProjectStore(), initialProject: project, cursorMemory: memory)
        XCTAssertEqual(show.snapshot.transport.position, project.songs[0].duration)
        XCTAssertFalse(show.isPlaying)
    }
}
