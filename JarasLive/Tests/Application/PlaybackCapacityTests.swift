import XCTest
@testable import JarasApplication

@MainActor private final class CapacityExecutor: CommandExecutor {
    var project = Project.empty(name: "Capacity")
    var transport = TransportState(playing: false, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0))
    var writes: [ShowCommand] = []
    func load(_ project: Project) throws { self.project = project; transport.songId = project.songs[0].id }
    func snapshot() throws -> ShowSnapshot { ShowSnapshot(project: project, transport: transport) }
    func applyProjectEdit(_ project: Project) throws { self.project = project }
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: transport) }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws {
        writes.append(command)
        switch command {
        case .tempo: project.songs[0].bpm = value
        case .play: transport.playing = true
        case .subPlay: transport.subPlay.playing = true
        case .stopAll: transport.playing = false; transport.subPlay.playing = false
        case .toggleLoop: transport.loop.enabled.toggle()
        default: break
        }
    }
    func addTrack(id: UUID, name: String, role: TrackRole) throws {}
    func advance(_ elapsed: Double) {}
    func finishCurrentSong(_ enabled: Bool) {}
}

final class PlaybackCapacityTests: XCTestCase {
    @MainActor func testRejectedControlsImmediatelyChangePresentationWithoutStop() throws {
        var project = project(251)
        let region = Part(id: UUID(), name: "Song", startTime: 0, endTime: 20)
        project.songs[0].parts = [region]
        let executor = CapacityExecutor(); executor.transport.playing = true
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        let before = show.presentationState
        show.send(.toggleLoop)
        XCTAssertNotEqual(show.presentationState, before)
        XCTAssertEqual(show.presentationState.capacityWarning, PlaybackCapacity.notice)
        XCTAssertTrue(show.snapshot.transport.playing)
        XCTAssertFalse(show.setTotalLoop(true, region: region.id))
        XCTAssertNotEqual(show.current?.parts.first?.totalLoop, true)
        XCTAssertTrue(executor.writes.isEmpty)
    }
    private func project(_ count: Int) -> Project {
        var project = Project.empty(name: "Capacity")
        project.songs[0].tracks = (0..<count).map { index in
            var track = Track(id: UUID(), name: "Track \(index)", role: .other)
            track.mute = true
            track.clips = [AudioClip(id: UUID(), name: "Shared", startTime: 0, duration: 20, audioFile: AudioFile(path: "same.wav"))]
            track.clips[0].muted = true
            return track
        }
        return project
    }
    func testCountsConcurrentFilesIncludingMutedCopiesAndBothHeads() {
        let project = project(251)
        var state = ShowSnapshot(project: project, transport: TransportState(playing: true,
            songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false),
            subPlay: SubPlayState(playing: false, position: 0)))
        XCTAssertEqual(PlaybackCapacity.active(state), 251)
        state.transport.subPlay.playing = true
        XCTAssertEqual(PlaybackCapacity.active(state), 502)
        XCTAssertTrue(PlaybackCapacity.exceeded(state))
        state.transport.position = 20
        XCTAssertEqual(PlaybackCapacity.active(state), 251)
        state.transport.subPlay.playing = false
        XCTAssertEqual(PlaybackCapacity.active(state), 0)
    }
    func testPeakScansWholeGridAndEndsPrecedeStartsWithoutCombiningSongs() {
        var project = project(251)
        XCTAssertEqual(PlaybackCapacity.peak(project), 251)
        for i in project.songs[0].tracks.indices { project.songs[0].tracks[i].clips[0].startTime = Double(i) * 20 }
        XCTAssertEqual(PlaybackCapacity.peak(project), 1)
        var other = project.songs[0]; other.id = UUID(); project.songs.append(other)
        XCTAssertEqual(PlaybackCapacity.peak(project), 1)
        project.songs[0].tracks[0].clips[0].audioFile = nil
        project.songs[0].tracks[1].clips[0].audioFile = AudioFile(path: "Images/still.png")
        XCTAssertEqual(PlaybackCapacity.peak(project), 1)
    }
    func testTwoHeadsAllow250EachWithoutUsingACombined250Limit() {
        let project = project(250)
        let state = ShowSnapshot(project: project, transport: TransportState(playing: true,
            songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false),
            subPlay: SubPlayState(playing: true, position: 0)))
        XCTAssertEqual(PlaybackCapacity.active(state), 500)
        XCTAssertFalse(PlaybackCapacity.exceeded(state))
    }
    @MainActor func testControllerRejectsBeforeAnyWriteAndKeepsStoppedTempoAvailable() throws {
        let executor = CapacityExecutor()
        executor.transport.playing = true
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project(251))
        executor.transport.playing = true; show.tick()
        executor.writes = []
        show.setTempo(121)
        show.send(.tempo, value: 122)
        show.send(.queueSection, target: UUID())
        show.send(.toggleLoop)
        XCTAssertTrue(executor.writes.isEmpty)
        XCTAssertEqual(show.capacityWarning, PlaybackCapacity.notice)
        show.send(.stopAll)
        show.setTempo(140)
        XCTAssertEqual(show.current?.bpm, 140)
        let writesBeforeRepeat = executor.writes.count
        show.send(.toggleLoop)
        XCTAssertEqual(executor.writes.count, writesBeforeRepeat)
        XCTAssertFalse(show.snapshot.transport.loop.enabled)
    }
    @MainActor func testDenseFreeTempoWithAudioOnlyKeepsPlaybackAndItemTiming() throws {
        var data = project(320)
        data.songs[0].timeSettings = .legacy
        let executor = CapacityExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: data)
        executor.transport.playing = true
        show.tick()
        show.setTempo(135)
        XCTAssertEqual(show.current?.bpm, 135)
        XCTAssertTrue(show.isPlaying)
        XCTAssertTrue(show.capacityWarning.isEmpty)
        XCTAssertEqual(show.current?.tracks, data.songs[0].tracks)
    }
    @MainActor func testRejectedControlNoticeExpiresAfterTwoSeconds() async throws {
        let executor = CapacityExecutor()
        executor.transport.playing = true
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project(251))
        executor.transport.playing = true; show.tick()
        show.send(.toggleLoop)
        XCTAssertEqual(show.capacityWarning, PlaybackCapacity.notice)
        try await Task.sleep(nanoseconds: 2_150_000_000)
        XCTAssertTrue(show.capacityWarning.isEmpty)
    }
    @MainActor func testSubplayWaitsWithoutStoppingPlayAndStopCancelsThePendingStart() async throws {
        let executor = CapacityExecutor()
        executor.transport.playing = true
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project(1))
        executor.transport.playing = true; show.tick()
        var releasePreparation: AsyncStream<Void>.Continuation?
        show.pendingSubplayPreparation = { _, _ in
            guard releasePreparation == nil else { return nil }
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            releasePreparation = continuation
            return Task { @MainActor in for await _ in stream {} }
        }
        show.send(.subPlay)
        XCTAssertTrue(show.preparingAudio)
        XCTAssertTrue(show.snapshot.transport.playing)
        XCTAssertFalse(show.snapshot.transport.subPlay.playing)
        releasePreparation?.finish()
        for _ in 0..<200 where !show.snapshot.transport.subPlay.playing {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(show.snapshot.transport.subPlay.playing)
        show.send(.stopAll)
        show.send(.play)
        releasePreparation = nil
        show.send(.subPlay)
        XCTAssertNotNil(releasePreparation)
        show.send(.stopAll)
        releasePreparation?.finish()
        await Task.yield()
        XCTAssertFalse(show.isPlaying)
        XCTAssertFalse(show.preparingAudio)
        XCTAssertEqual(executor.writes.filter { $0 == .subPlay }.count, 1)
    }
}
