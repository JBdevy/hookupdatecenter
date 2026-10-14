import XCTest
@testable import JarasApplication

@MainActor private final class CapturedPluginExecutor: CommandExecutor {
    var project = Project.empty(name: "Captured presets")
    var commands = 0, writes = 0
    var failWrites = false
    func load(_ project: Project) throws { self.project = project }
    func snapshot() throws -> ShowSnapshot {
        ShowSnapshot(project: project, transport: TransportState(playing: true, songId: project.songs[0].id,
            position: 25, editPosition: 10, queue: QueueState(), loop: LoopState(enabled: false),
            subPlay: SubPlayState(playing: false, position: 0)))
    }
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: try snapshot().transport) }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws { commands += 1 }
    func addTrack(id: UUID, name: String, role: TrackRole) throws {}
    func advance(_ elapsed: Double) {}
    func finishCurrentSong(_ enabled: Bool) {}
    func applyProjectEdit(_ project: Project) throws { self.project = project }
    func setFX(_ track: UUID?, settings: NativeFXSettings) throws {
        if failWrites { throw ProjectError.invalid("Rejected preset") }
        writes += 1
        if let track, let index = project.songs[0].tracks.firstIndex(where: { $0.id == track }) { project.songs[0].tracks[index].fx = settings }
        else { project.masterFX = settings }
    }
    func setClipFX(_ clip: UUID, settings: NativeFXSettings) throws {
        if failWrites { throw ProjectError.invalid("Rejected preset") }
        writes += 1
        for track in project.songs[0].tracks.indices {
            if let index = project.songs[0].tracks[track].clips.firstIndex(where: { $0.id == clip }) {
                project.songs[0].tracks[track].clips[index].fx = settings; return
            }
        }
    }
}

final class CapturedPluginSaveTests: XCTestCase {
    private func fixture() -> (Project, UUID, UUID, String) {
        var project = Project.empty(name: "Capture during playback")
        let plugin = ExternalPlugin(classID: "1234123456785678ABCDEF0012345678", name: "Gain", path: "/tmp/Gain.vst3")
        var fx = NativeFXSettings(); fx.externalPlugins = [plugin]; fx.inserted = [plugin.effectKey]
        var clip = AudioClip(id: UUID(), name: "Take", startTime: 0, duration: 60); clip.fx = fx
        var track = Track(id: UUID(), name: "Track", role: .other); track.fx = fx; track.clips = [clip]
        project.songs[0].duration = 60; project.songs[0].tracks = [track]; project.masterFX = fx
        return (project, track.id, clip.id, plugin.id)
    }
    @MainActor func testSavingCapturedMasterTrackAndTakePresetsDoesNotRepublishAudioOrTouchTransport() async throws {
        let (project, track, clip, plugin) = fixture()
        let executor = CapturedPluginExecutor(), store = MemoryProjectStore()
        let show = try ShowController(executor: executor, persistence: store, initialProject: project)
        let transport = show.snapshot.transport
        var audioUpdates = 0, fxUpdates = 0, takeUpdates = 0
        show.audioUpdate = { _, _ in audioUpdates += 1 }
        show.audioFX = { _, _ in fxUpdates += 1 }; show.audioClipFX = { _, _ in takeUpdates += 1 }
        show.prepareForSave = {
            XCTAssertTrue(try show.storeCapturedPluginState(nil, identifier: plugin, componentState: "AAAAAA==", controllerState: nil))
            XCTAssertTrue(try show.storeCapturedPluginState(track, identifier: plugin, componentState: "AACAPw==", controllerState: nil))
            XCTAssertTrue(try show.storeCapturedPluginState(nil, clip: clip, identifier: plugin, componentState: "AAAAPw==", controllerState: nil))
        }
        try await show.flushProject()
        XCTAssertEqual(audioUpdates, 0); XCTAssertEqual(fxUpdates, 0); XCTAssertEqual(takeUpdates, 0)
        XCTAssertEqual(executor.commands, 0); XCTAssertEqual(executor.writes, 3)
        XCTAssertEqual(show.snapshot.transport, transport)
        XCTAssertEqual(executor.project, show.snapshot.project)
        let loaded = await store.load()
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.masterFX?.externalPlugins?.first?.componentState, "AAAAAA==")
        XCTAssertEqual(saved.songs[0].tracks[0].fx?.externalPlugins?.first?.componentState, "AACAPw==")
        XCTAssertEqual(saved.songs[0].tracks[0].clips[0].fx?.externalPlugins?.first?.componentState, "AAAAPw==")
        XCTAssertFalse(show.hasUnsavedChanges)
        XCTAssertTrue(show.canUndo)
        show.undo()
        XCTAssertNil(show.current?.tracks[0].clips[0].fx?.externalPlugins?.first?.componentState)
        show.redo()
        XCTAssertEqual(show.current?.tracks[0].clips[0].fx?.externalPlugins?.first?.componentState, "AAAAPw==")
    }
    @MainActor func testCaptureRejectsMissingTargetsAndNoOpButKeepsFailedCapturePending() throws {
        let (project, track, clip, plugin) = fixture()
        let executor = CapturedPluginExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        XCTAssertFalse(try show.storeCapturedPluginState(UUID(), identifier: plugin, componentState: "AAAAAA==", controllerState: nil))
        XCTAssertFalse(try show.storeCapturedPluginState(nil, clip: UUID(), identifier: plugin, componentState: "AAAAAA==", controllerState: nil))
        XCTAssertFalse(try show.storeCapturedPluginState(track, identifier: "missing", componentState: "AAAAAA==", controllerState: nil))
        XCTAssertFalse(try show.storeCapturedPluginState(nil, clip: clip, identifier: plugin, componentState: nil, controllerState: nil))
        executor.failWrites = true
        XCTAssertThrowsError(try show.storeCapturedPluginState(track, identifier: plugin, componentState: "AAAAAA==", controllerState: nil))
        XCTAssertThrowsError(try show.storeCapturedPluginState(nil, clip: clip, identifier: plugin, componentState: "AAAAAA==", controllerState: nil))
        XCTAssertEqual(show.snapshot.project, project); XCTAssertTrue(show.hasUnsavedChanges); XCTAssertFalse(show.canUndo)
        XCTAssertEqual(executor.writes, 0)
    }
}
