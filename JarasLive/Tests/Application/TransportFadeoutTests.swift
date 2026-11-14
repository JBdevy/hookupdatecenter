import XCTest
import AVFoundation
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
    @MainActor func testConfigRateAcceptsMIDIAndGeneratedSpecialItemsInOneUndoableEdit() throws {
        let executor = FadeoutExecutor()
        var project = Project.empty(name: "All rate item types")
        let region = Part(id: UUID(), name: "Song", startTime: 0, endTime: 10)
        project.songs[0].parts = [region]; project.songs[0].duration = 20
        var tc = Track(id: UUID(), name: "Timecode", role: .init(rawValue: "timecode"))
        tc.clips = [.init(id: Project.timecodeItemID(region.id), name: "LTC", startTime: 0, duration: 10, regionOwnerID: region.id)]
        var click = Track(id: UUID(), name: "Click", role: .init(rawValue: "generatedClick"))
        click.clips = [.init(id: Project.clickItemID(region.id), name: "Click", startTime: 0, duration: 10, regionOwnerID: region.id)]
        var midi = Track(id: UUID(), name: "MIDI", role: .other)
        midi.clips = [.init(id: UUID(), name: "MIDI", startTime: 0, duration: 10, midi: MIDIItem(notes: [.init(start: 2, length: 2, pitch: 60)]))]
        project.songs[0].tracks = [tc, click, midi]
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        let ids = Set(project.songs[0].tracks.flatMap(\.clips).map(\.id))
        XCTAssertTrue(show.configureItemsRate(ids, rate: 2))
        XCTAssertEqual(show.current?.tracks.flatMap(\.clips).map(\.duration), [5,5,5])
        XCTAssertEqual(show.current?.tracks.flatMap(\.clips).map(\.audioRate), [2,2,2])
        XCTAssertEqual(show.current?.tracks[0].clips[0].timecodeEndOffset, -5)
        XCTAssertEqual(executor.projectEdits, 1)
        show.undo(); XCTAssertEqual(show.snapshot.project, project)
    }

    @MainActor func testSavingUnchangedPreciseRateDoesNotChangeGeometryOrCreateUndo() throws {
        let executor = FadeoutExecutor()
        var project = Project.empty(name: "Precise rate")
        var track = Track(id: UUID(), name: "Audio", role: .other)
        let exact = 1.1234567890123456
        let clip = AudioClip(id: UUID(), name: "Reference", startTime: 0.667123456789, duration: 184.66123456789,
                             sourceOffset: 0.123456789012345, audioFile: AudioFile(path: "source.wav"), playbackRate: exact)
        track.clips = [clip]; project.songs[0].tracks = [track]; project.songs[0].duration = 200
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        XCTAssertTrue(show.configureItemsRate([clip.id], rate: exact))
        XCTAssertEqual(show.current?.tracks[0].clips[0], clip)
        XCTAssertEqual(executor.projectEdits, 0)
    }
    @MainActor func testSetlistSpacingIsOneUndoableEditAndKeepsTimebaseAndAutomation() throws {
        let executor = FadeoutExecutor()
        var project = Project.empty(name: "Setlist spacing")
        let a = Part(id: UUID(), name: "A", startTime: 0, endTime: 50)
        let b = Part(id: UUID(), name: "B", startTime: 100, endTime: 150)
        let c = Part(id: UUID(), name: "C", startTime: 200, endTime: 250)
        project.songs[0].parts = [a,b,c]; project.songs[0].duration = 300
        project.songs[0].timeSettings = ProjectTimeSettings(); project.songs[0].timeSettings?.timebase = .relative
        var track = Track(id: UUID(), name: "Audio", role: .other)
        track.clips = [AudioClip(id: UUID(), name: "Tail", startTime: 10, duration: 70),
                       AudioClip(id: UUID(), name: "B", startTime: 110, duration: 20),
                       AudioClip(id: UUID(), name: "C", startTime: 210, duration: 20)]
        project.songs[0].tracks = [track]
        var master = TrackAutomation()
        var envelope = TrackEnvelope(target: AutomationTarget(.volume), name: "Volume", defaultValue: 0.5)
        envelope.points = [.init(time: 15, value: 0.3), .init(time: 215, value: 0.8)]
        master.envelopes = [envelope]; project.masterAutomation = master
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        show.fitRegionEndsToItems([a.id]); XCTAssertEqual(show.current?.parts[0].endTime, 80)
        let before = show.snapshot.project
        show.spaceRegionsAfter([a.id,b.id])
        XCTAssertEqual(show.current?.parts.map(\.startTime), [0,130,260])
        XCTAssertEqual(show.current?.tracks[0].clips.map(\.startTime), [10,140,270])
        XCTAssertEqual(show.snapshot.project.masterAutomation?.envelopes[0].points.map(\.time), [15,275])
        XCTAssertEqual(show.current?.projectTime.timebase, .relative)
        XCTAssertEqual(executor.projectEdits, 2)
        show.undo(); XCTAssertEqual(show.snapshot.project, before)
    }
    @MainActor func testResetDurationReadsRealFileCommitsOnceAndCanBeUndone() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: directory.appendingPathComponent("Source.wav"), settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000)!
            buffer.frameLength = 96000
            buffer.floatChannelData![0].initialize(repeating: 0, count: 96000)
            try file.write(from: buffer)
        }
        let executor = FadeoutExecutor()
        var project = Project.empty(name: "Duration")
        var track = Track(id: UUID(), name: "Audio", role: .other)
        let clip = AudioClip(id: UUID(), name: "Trimmed", startTime: 4, duration: 0.2, sourceOffset: 0.75,
                             audioFile: AudioFile(path: "Source.wav"), playbackRate: 1.25)
        track.clips = [clip]; project.songs[0].tracks = [track]
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        await show.resetItemsDuration([clip.id], mediaDirectory: directory)
        XCTAssertEqual(show.message, "")
        let restored = try XCTUnwrap(show.current?.tracks[0].clips[0])
        XCTAssertEqual(restored.startTime, 4); XCTAssertEqual(restored.duration, 1.6, accuracy: 1e-9)
        XCTAssertEqual(restored.sourceOffset, 0); XCTAssertEqual(restored.audioRate, 1.25)
        XCTAssertEqual(executor.projectEdits, 1)
        show.undo(); XCTAssertEqual(show.current?.tracks[0].clips[0], clip)
        XCTAssertTrue(show.configureItemsRate([clip.id], rate: 2.5))
        XCTAssertEqual(show.current!.tracks[0].clips[0].duration, 0.1, accuracy: 1e-9)
        XCTAssertEqual(show.current!.tracks[0].clips[0].sourceOffset, 0.75)
        show.undo(); XCTAssertEqual(show.current?.tracks[0].clips[0], clip)
        show.itemSourceInfo = { _ in (directory.appendingPathComponent("Source.wav"), nil) }
        show.resizeItem(clip.id, start: 4, end: 8)
        for _ in 0..<100 {
            if show.current?.tracks[0].clips[0].loopLength != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(show.current?.tracks[0].clips[0].loopLength, 2)
        XCTAssertEqual(show.current?.tracks[0].clips[0].duration, 4)
    }
    @MainActor func testResetRatePreservesMarkersOtherItemsAndItemGeometry() throws {
        let executor = FadeoutExecutor()
        var project = Project.empty(name: "Reset rate")
        let item = AudioClip(id: UUID(), name: "Audio", startTime: 2, duration: 5, sourceOffset: 3,
                             audioFile: AudioFile(path: "source.wav"), playbackRate: 1.5, tempoBasePlaybackRate: 1.2)
        let other = AudioClip(id: UUID(), name: "Other", startTime: 0, duration: 9, playbackRate: 0.8)
        var track = Track(id: UUID(), name: "Track", role: .other)
        track.clips = [item, other]; project.songs[0].tracks = [track]
        project.songs[0].bpm = 120
        let marker = TimelineMarker(id: UUID(), name: "Tempo", position: 4, color: 0,
                                   tempoBPM: 140, tempoTimebase: .relative, tempoReferenceBPM: 120)
        project.songs[0].markers = [marker]
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: project)
        show.resetItemsRate([item.id])
        var expected = project
        expected.songs[0].tracks[0].clips[0].playbackRate = 1
        expected.songs[0].tracks[0].clips[0].tempoBasePlaybackRate = nil
        expected.songs[0].tracks[0].clips[0].tempoRateReferences = [.init(markerID: marker.id, rate: 140.0 / 120)]
        XCTAssertEqual(show.snapshot.project, expected)
        XCTAssertEqual(show.current!.tempoAudioSegments(show.current!.tracks[0].clips[0]).map(\.audioRate), [1])
        show.undo(); XCTAssertEqual(show.snapshot.project, project)
        XCTAssertTrue(show.configureItemsRate([item.id], rate: 1, resetTempo: true))
        XCTAssertEqual(show.snapshot.project, expected)
    }

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
    @MainActor func testSMKFaderIsSilentStoppedAndReportsOnlyAnActualCancellation() throws {
        let (show, _, clock) = try fixture()
        var messages: [String] = []; show.smkFeedback = { label, _ in messages.append(label) }
        show.performSMKAction(.fadeout(true)); show.performSMKAction(.fadeout(false))
        XCTAssertTrue(messages.isEmpty); XCTAssertFalse(show.transportFadeout.active)
        show.send(.play); show.performSMKAction(.fadeout(false)); XCTAssertTrue(messages.isEmpty)
        show.performSMKAction(.fadeout(true)); XCTAssertTrue(show.transportFadeout.active)
        clock(101); show.tick(); XCTAssertEqual(show.transportFadeout.run?.remaining, 4)
        show.performSMKAction(.fadeout(false)); XCTAssertEqual(messages, ["FADE OUT CANCELADO"])
        XCTAssertTrue(show.snapshot.transport.playing)
        show.performSMKAction(.fadeout(false)); XCTAssertEqual(messages.count, 1)
        show.send(.stop); show.performSMKAction(.fadeout(true)); XCTAssertEqual(messages.count, 1)
    }
    @MainActor func testExplicitButtonWorksWithoutShortcutEnablementAndCancelsWithoutStopping() throws {
        let (show, executor, clock) = try fixture()
        let before = show.snapshot.project
        let ids = Set(show.fadeoutTracks.map(\.id))
        show.configureTransportFadeout(enabled: false, duration: 2, tracks: ids)
        show.triggerTransportFadeout(explicit: true)
        XCTAssertFalse(show.transportFadeout.active, "Fadeout never starts playback")
        show.send(.play); show.triggerTransportFadeout()
        XCTAssertFalse(show.transportFadeout.active, "Disabled legacy shortcut remains disabled")
        show.triggerTransportFadeout(explicit: true)
        XCTAssertTrue(show.transportFadeout.active)
        clock(101); show.tick()
        XCTAssertEqual(show.transportFadeout.run?.remaining, 1)
        show.triggerTransportFadeout(explicit: true)
        XCTAssertFalse(show.transportFadeout.active)
        XCTAssertTrue(show.snapshot.transport.playing)
        XCTAssertFalse(executor.commands.contains(.stop))
        XCTAssertEqual(show.snapshot.project, before)
        XCTAssertFalse(show.transportFadeout.enabled, "Explicit button does not rewrite shortcut preferences")
        show.send(.stop)
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
