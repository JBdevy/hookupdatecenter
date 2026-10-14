import XCTest
@testable import JarasApplication

@MainActor private final class EditClockExecutor: CommandExecutor {
    var project = Project.empty(name: "Edit clock")
    var transport = TransportState(playing: true, position: 5, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: true, position: 20))
    var editCost: () -> Void = {}
    func load(_ project: Project) throws { self.project = project; transport.songId = project.songs[0].id }
    func snapshot() throws -> ShowSnapshot { ShowSnapshot(project: project, transport: transport) }
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: transport) }
    func advance(_ elapsed: Double) {
        if transport.playing { transport.position += elapsed }
        if transport.subPlay.playing { transport.subPlay.position += elapsed }
    }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws {
        switch command {
        case .mute:
            if let index = project.songs[0].tracks.firstIndex(where: { $0.id == target }) { project.songs[0].tracks[index].mute.toggle() }
        case .clipMute:
            for track in project.songs[0].tracks.indices {
                if let item = project.songs[0].tracks[track].clips.firstIndex(where: { $0.id == target }) {
                    project.songs[0].tracks[track].clips[item].muted = !(project.songs[0].tracks[track].clips[item].muted ?? false)
                }
            }
        case .seek: transport.position = value
        case .subSeek: transport.subPlay.position = value
        case .stopAll: transport.playing = false; transport.subPlay.playing = false
        default: break
        }
    }
    func applyProjectEdit(_ project: Project) throws { self.project = project; editCost() }
    func reorderTrack(_ track: UUID, before: UUID?) throws {
        let index = project.songs[0].tracks.firstIndex(where: { $0.id == track })!
        let moved = project.songs[0].tracks.remove(at: index)
        let destination = project.songs[0].tracks.firstIndex(where: { $0.id == before }) ?? project.songs[0].tracks.count
        project.songs[0].tracks.insert(moved, at: destination); editCost()
    }
    func insertAudioTracks(_ tracks: [Track], song: UUID) throws {
        project.songs[0].tracks.append(contentsOf: tracks); editCost()
    }
    func setFX(_ track: UUID?, settings: NativeFXSettings) throws {
        if let index = project.songs[0].tracks.firstIndex(where: { $0.id == track }) { project.songs[0].tracks[index].fx = settings }
        else { project.masterFX = settings }
    }
    func addTrack(id: UUID, name: String, role: TrackRole) throws {}
    func finishCurrentSong(_ enabled: Bool) {}
}

final class PlaybackEditClockTests: XCTestCase {
    @MainActor private func fixture() throws -> (ShowController, EditClockExecutor, () -> Double, () -> Void) {
        var now = 100.0
        var project = Project.empty(name: "Live editing")
        project.songs[0].duration = 100
        project.songs[0].tracks = [Track(id: UUID(), name: "First", role: .other), Track(id: UUID(), name: "Second", role: .other)]
        project.songs[0].tracks[0].clips = [AudioClip(id: UUID(), name: "Stem", startTime: 0, duration: 90,
            audioFile: AudioFile(path: "Stems/stem.wav"))]
        let executor = EditClockExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project, playbackClock: { now })
        return (show, executor, { now }, { now += 0.3 })
    }

    /// No sleep or CPU threshold: the fake clock advances inside the operation,
    /// while the published transport retains its original sample epoch until tick.
    @MainActor private func observe(_ show: ShowController, now: @escaping () -> Double) -> () -> Int {
        var publications = 0
        show.audioUpdate = { snapshot, _ in
            publications += 1
            XCTAssertEqual(snapshot.transport.position, 5 + show.timelinePlaybackSampleTime - 100, accuracy: 0.000001,
                           "An edit must preserve the timestamp belonging to its transport sample")
            XCTAssertEqual(snapshot.transport.subPlay.position, 20 + show.timelinePlaybackSampleTime - 100, accuracy: 0.000001,
                           "Sub Play must share the exact transport sample epoch")
        }
        return { publications }
    }

    @MainActor func testRepeatedTrackAndItemMutePreserveSampleEpochWithoutExtraTicks() throws {
        let (show, _, now, delay) = try fixture()
        let track = show.current!.tracks[0].id, clip = show.current!.tracks[0].clips[0].id
        let count = observe(show, now: now)
        show.audioMute = { _, _ in delay() }; show.audioClipMute = { _, _ in delay() }
        for _ in 0..<4 { show.send(.mute, target: track); show.send(.clipMute, target: clip) }
        XCTAssertEqual(count(), 8)
        show.tick()
        XCTAssertEqual(show.snapshot.transport.position, 5 + now() - 100, accuracy: 0.000001)
        XCTAssertFalse(show.current!.tracks[0].mute)
        XCTAssertFalse(show.current!.tracks[0].clips[0].muted == true)
    }

    @MainActor func testSlowEffectInsertionPreservesSampleEpoch() throws {
        let (show, _, now, delay) = try fixture()
        let count = observe(show, now: now)
        show.audioFX = { _, _ in delay() }
        for _ in 0..<4 { XCTAssertNotNil(show.insertFX(show.current!.tracks[0].id, effect: "Delay")) }
        XCTAssertEqual(count(), 4)
        show.tick()
        XCTAssertEqual(show.snapshot.transport.position, 5 + now() - 100, accuracy: 0.000001)
    }

    @MainActor func testDeleteUndoRedoInsertionAndReorderingPreserveSampleEpoch() throws {
        let (show, executor, now, delay) = try fixture()
        let clip = show.current!.tracks[0].clips[0].id
        let first = show.current!.tracks[0].id, second = show.current!.tracks[1].id
        let count = observe(show, now: now)
        executor.editCost = delay
        show.deleteItems([clip])
        XCTAssertTrue(show.current!.tracks[0].clips.isEmpty)
        show.undo(); XCTAssertEqual(show.current!.tracks[0].clips.first?.id, clip)
        show.redo(); XCTAssertTrue(show.current!.tracks[0].clips.isEmpty)
        show.reorderTrack(second, before: first)
        XCTAssertEqual(show.current!.tracks[0].id, second)
        let extra = Track(id: UUID(), name: "New", role: .other)
        try show.insertAudioTracks([extra], song: show.current!.id, project: show.snapshot.project.id)
        XCTAssertEqual(show.current!.tracks.last?.id, extra.id)
        XCTAssertGreaterThanOrEqual(count(), 5)
    }

    @MainActor func testExplicitSeeksAndStoppedEditsKeepTheirOwnPositions() throws {
        let (show, _, _, delay) = try fixture()
        show.audioMute = { _, _ in delay() }
        show.send(.mute, target: show.current!.tracks[0].id)
        show.send(.seek, value: 40)
        XCTAssertEqual(show.snapshot.transport.position, 40, accuracy: 0.000001)
        show.send(.subSeek, value: 60)
        XCTAssertEqual(show.snapshot.transport.subPlay.position, 60, accuracy: 0.000001)
        show.send(.stopAll)
        let stopped = show.snapshot.transport
        show.send(.mute, target: show.current!.tracks[0].id)
        XCTAssertEqual(show.snapshot.transport.position, stopped.position)
        XCTAssertEqual(show.snapshot.transport.subPlay.position, stopped.subPlay.position)
    }
}
