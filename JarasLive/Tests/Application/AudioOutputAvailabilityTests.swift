import XCTest
@testable import JarasApplication

@MainActor private final class OutputExecutor: CommandExecutor {
    var project = Project.empty(name: "Output test")
    var transport = TransportState(playing: false, position: 1, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0))
    var commands: [ShowCommand] = []
    func load(_ project: Project) throws { self.project = project; transport.songId = project.songs.first?.id }
    func snapshot() throws -> ShowSnapshot { ShowSnapshot(project: project, transport: transport) }
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: transport) }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws {
        commands.append(command)
        if command == .play { transport.playing = true }
        if command == .stopAll { transport.playing = false; transport.subPlay.playing = false }
    }
    func applyProjectEdit(_ project: Project) throws { self.project = project }
    func addTrack(id: UUID, name: String, role: TrackRole) throws {}
    func advance(_ elapsed: Double) {}
    func finishCurrentSong(_ enabled: Bool) {}
}
final class AudioOutputAvailabilityTests: XCTestCase {
    @MainActor func testEveryPlayWarnsUntilSelectedOutputReturns() throws {
        let executor = OutputExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: executor.project)
        var validations = 0
        show.validateAudioOutput = { validations += 1; throw ProjectError.invalid("The selected audio output is disconnected.") }
        for _ in 0..<3 {
            show.modalNotice = nil
            show.send(.play)
            XCTAssertFalse(show.isPlaying)
            XCTAssertNotNil(show.modalNotice)
        }
        XCTAssertEqual(validations,3)
        XCTAssertFalse(executor.commands.contains(.play))
        show.validateAudioOutput = {}
        show.send(.play)
        XCTAssertTrue(show.isPlaying)
    }
    @MainActor func testDeviceLossStopsBothHeadsAndWarnsWithoutChangingSavedProject() throws {
        let executor = OutputExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: executor.project)
        show.send(.play)
        executor.transport.subPlay.playing = true
        var stopped = 0, audioStopped = false
        show.onStop = { stopped += 1 }
        show.audioUpdate = { state, _ in audioStopped = !state.transport.playing && !state.transport.subPlay.playing }
        let id = show.snapshot.project.id
        show.audioOutputDisconnected("Audio device disconnected. Playback stopped.")
        XCTAssertFalse(show.isPlaying)
        XCTAssertFalse(show.snapshot.transport.subPlay.playing)
        XCTAssertTrue(audioStopped)
        XCTAssertEqual(stopped,1)
        XCTAssertEqual(show.snapshot.project.id,id)
        XCTAssertEqual(show.modalNotice,"Audio device disconnected. Playback stopped.")
    }
}
