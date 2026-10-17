import XCTest
@testable import JarasApplication

@MainActor private final class FadeoutExecutor: CommandExecutor {
    var project = Project.empty(name: "Fadeout")
    var transport = TransportState(playing: false, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0))
    var commands: [ShowCommand] = []
    var projectEdits = 0
    func load(_ project: Project) throws { self.project = project; transport.songId = project.songs[0].id; transport.playing = false }
    func snapshot() throws -> ShowSnapshot { ShowSnapshot(project: project, transport: transport) }
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: transport) }
    func advance(_ elapsed: Double) { if transport.playing { transport.position += elapsed } }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws {
        commands.append(command)
        switch command {
        case .play: transport.playing = true
        case .stop, .stopAll, .pause: transport.playing = false; transport.subPlay.playing = false
        case .subPlay: transport.subPlay.playing = true
        case .subStop: transport.subPlay.playing = false
        default: break
        }
    }
    func applyProjectEdit(_ project: Project) throws { self.project = project; projectEdits += 1 }
    func addTrack(id: UUID, name: String, role: TrackRole) throws {}
    func finishCurrentSong(_ enabled: Bool) {}
}
final class TransportFadeoutTests: XCTestCase {
    @MainActor private func fixture() throws -> (ShowController, FadeoutExecutor, (Double) -> Void) {
        var now = 100.0
        let executor = FadeoutExecutor()
        var p = Project.empty(name: "Fade")
        p.songs[0].duration = 100
        p.songs[0].tracks = [Track(id: UUID(), name: "One", role: .other), Track(id: UUID(), name: "Two", role: .other)]
        p.songs[0].tracks[0].volume = 0.7; p.songs[0].tracks[1].volume = 1.4
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: p, playbackClock: { now })
        show.configureTransportFadeout(enabled: true, duration: 5, tracks: [p.songs[0].tracks[0].id])
        return (show, executor, { now = $0 })
    }
    @MainActor func testFadeStopsAfterSilentEndpointThenRestoresWithoutEditingProject() throws {
        let (show, executor, clock) = try fixture()
        let before = show.snapshot.project, selected = before.songs[0].tracks[0].id, other = before.songs[0].tracks[1].id
        var gains: [UUID:Double] = [:], events: [String] = []
        show.audioTransportFade = { gains = $0; events.append($0.isEmpty ? "restore" : "gain") }
        show.audioUpdate = { snapshot, _ in
            if !snapshot.transport.playing { XCTAssertEqual(gains[selected], 0); events.append("stop") }
        }
        show.send(.play); show.performAction(.transportFadeout)
        XCTAssertEqual(show.transportFadeout.run?.remaining, 5)
        clock(100.1); show.tick()
        XCTAssertEqual(show.transportFadeout.run!.remaining, 4.9, accuracy: 0.000001)
        XCTAssertEqual(gains[selected]!, 0.98, accuracy: 0.000001)
        XCTAssertNil(gains[other]); XCTAssertTrue(show.snapshot.transport.playing)
        clock(105); show.tick()
        XCTAssertFalse(show.snapshot.transport.playing); XCTAssertFalse(show.transportFadeout.active)
        XCTAssertEqual(Array(events.suffix(3)), ["gain", "stop", "restore"])
        XCTAssertEqual(show.snapshot.project, before); XCTAssertEqual(executor.projectEdits, 0)
        XCTAssertEqual(show.current!.tracks[0].volume, 0.7); XCTAssertEqual(show.current!.tracks[1].volume, 1.4)
    }
    @MainActor func testRepeatActionCancelsAndKeepsPlaybackAndRestoresVisuals() throws {
        let (show, executor, clock) = try fixture()
        var gains: [UUID:Double] = [:]; show.audioTransportFade = { gains = $0 }
        show.send(.play); show.triggerTransportFadeout(); clock(102); show.tick()
        let track = show.current!.tracks[0].id
        XCTAssertEqual(show.transportFadeout.multiplier(for: track), 0.6, accuracy: 0.000001)
        show.performAction(.transportFadeout)
        XCTAssertTrue(show.snapshot.transport.playing); XCTAssertFalse(show.transportFadeout.active)
        XCTAssertTrue(gains.isEmpty); XCTAssertEqual(show.transportFadeout.multiplier(for: track), 1)
        XCTAssertFalse(executor.commands.contains(.stop)); show.send(.stop)
    }
    @MainActor func testSubplayIsMutuallyExclusiveAndNormalStopRemainsImmediate() throws {
        let (show, executor, _) = try fixture()
        show.triggerTransportFadeout(); XCTAssertFalse(show.transportFadeout.active)
        show.send(.play); show.send(.subPlay); show.triggerTransportFadeout()
        XCTAssertFalse(show.transportFadeout.active); XCTAssertNotNil(show.transportFadeout.notice)
        show.send(.subStop); show.triggerTransportFadeout()
        let count = executor.commands.count
        show.send(.subPlay); XCTAssertEqual(executor.commands.count, count)
        XCTAssertFalse(show.snapshot.transport.subPlay.playing); XCTAssertTrue(show.transportFadeout.active)
        XCTAssertNotNil(show.transportFadeout.notice)
        show.performAction(.playStop)
        XCTAssertFalse(show.snapshot.transport.playing); XCTAssertFalse(show.transportFadeout.active)
    }
    @MainActor func testConfigurationIsProjectScopedAndRangeIsOneToFiveSeconds() {
        let suite = "FadeoutTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = TransportFadeout(), project = UUID(), track = UUID()
        model.load(project: project, defaults: defaults)
        XCTAssertFalse(model.enabled); XCTAssertTrue(model.trackIDs.isEmpty)
        model.configure(enabled: true, duration: 999, tracks: [track]); XCTAssertEqual(model.duration, 5)
        model.load(project: UUID(), defaults: defaults); XCTAssertTrue(model.trackIDs.isEmpty)
        model.load(project: project, defaults: defaults); XCTAssertEqual(model.trackIDs, [track])
        model.configure(enabled: true, duration: -1, tracks: []); XCTAssertEqual(model.duration, 1)
        XCTAssertEqual(TransportFadeout.validDuration(.nan), 3)
    }
    @MainActor func testReplacementCancelsAndNeverCarriesTrackIDsToAnotherProject() throws {
        let (show, _, _) = try fixture(); show.send(.play); show.triggerTransportFadeout()
        var last: [UUID:Double] = [UUID(): 0]; show.audioTransportFade = { last = $0 }
        try show.replaceProject(.empty(name: "Other"))
        XCTAssertFalse(show.transportFadeout.active); XCTAssertTrue(last.isEmpty); XCTAssertTrue(show.transportFadeout.trackIDs.isEmpty)
    }
    func testFadeoutShortcutCannotStealReservedOrOccupiedKeysAndMIDIRemainsAvailable() {
        var bindings = DAWActionBindings()
        XCTAssertNil(bindings.binding(.transportFadeout).keyboard)
        XCTAssertTrue(DAWAction.transportFadeout.supportsMIDI)
        for flags: UInt in [0, 1<<17, 1<<18, 1<<19, 1<<20] {
            XCTAssertFalse(bindings.transferInput(ControlInput(kind: "keyboard", label: "Space", key: 49, modifiers: flags), action: .transportFadeout, kind: "keyboard"))
        }
        for input in [ControlInput(kind: "keyboard", label: "Create region", key: 15, modifiers: 1<<17),
                      ControlInput(kind: "keyboard", label: "Marker", key: 46, modifiers: 1<<19),
                      ControlInput(kind: "keyboard", label: "Undo", key: 6, modifiers: 1<<20)] {
            XCTAssertFalse(bindings.setInput(input, action: .transportFadeout, kind: "keyboard"))
        }
        let original = DAWAction.muteTrack.defaultKeyboard!
        XCTAssertTrue(bindings.setInput(nil, action: .muteTrack, kind: "keyboard"))
        XCTAssertFalse(bindings.setInput(original, action: .transportFadeout, kind: "keyboard"))
        let custom = ControlInput(kind: "keyboard", label: "F8", key: 100, modifiers: 0)
        XCTAssertTrue(bindings.setInput(custom, action: .pause, kind: "keyboard"))
        XCTAssertFalse(bindings.transferInput(custom, action: .transportFadeout, kind: "keyboard"))
        XCTAssertEqual(bindings.matching(custom), .pause)
        XCTAssertTrue(bindings.setInput(nil, action: .pause, kind: "keyboard"))
        XCTAssertTrue(bindings.setInput(custom, action: .transportFadeout, kind: "keyboard"))
        let midi = ControlInput(kind: "midi", label: "CC", device: 1, channel: 0, status: 0xb0, number: 12)
        XCTAssertTrue(bindings.setInput(midi, action: .transportFadeout, kind: "midi"))
        XCTAssertEqual(bindings.matching(midi), .transportFadeout)
    }
}
