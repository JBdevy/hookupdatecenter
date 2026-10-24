import XCTest
@testable import JarasApplication

@MainActor private final class TrackCopyExecutor: CommandExecutor {
    var project = Project.empty(name: "Track copy")
    var transport = TransportState(playing: true, position: 23, editPosition: 15, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0))
    var edits = 0
    func load(_ value: Project) throws { try value.validate(); project = value; transport.songId = value.songs[0].id }
    func snapshot() throws -> ShowSnapshot { ShowSnapshot(project: project, transport: transport) }
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: transport) }
    func applyProjectEdit(_ value: Project) throws { try value.validate(); project = value; edits += 1 }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws {}
    func addTrack(id: UUID, name: String, role: TrackRole) throws {}
    func advance(_ elapsed: Double) {}
    func finishCurrentSong(_ enabled: Bool) {}
    func setFX(_ track: UUID?, settings: NativeFXSettings) throws {
        guard let index = project.songs[0].tracks.firstIndex(where: { $0.id == track }) else { return }
        project.songs[0].tracks[index].fx = settings
    }
    func setClipFX(_ id: UUID, settings: NativeFXSettings) throws {
        for track in project.songs[0].tracks.indices {
            if let item = project.songs[0].tracks[track].clips.firstIndex(where: { $0.id == id }) {
                project.songs[0].tracks[track].clips[item].fx = settings
            }
        }
    }
}

final class TrackDuplicationTests: XCTestCase {
    private func fixture() -> Project {
        var project = Project.empty(name: "Track copy")
        var track = Track(id: UUID(), name: "Piano", role: .keys)
        track.volume = 0.7; track.pan = -0.25; track.phaseInverted = true; track.heightScale = 0.7
        track.instrumentIcon = "piano"
        track.mute = true; track.solo = true; track.color = 0x123456
        track.midiInput = 2; track.midiChannel = 3; track.inputMonitoring = true
        track.inputPatch = OutputPatch(firstChannel: 3, channelCount: 2)
        track.outputs = [.master, OutputPatch(firstChannel: 5, channelCount: 2)]
        track.recordingChannels = 2; track.recordingFormat = "wav32"
        var fx = NativeFXSettings(); fx.appendNative("EQ"); fx.bands[2].gain = -5
        let repeated = fx.appendNative("EQ"); var nested = fx.settings(for: repeated); nested.bands[1].gain = 7
        fx = fx.merging(effect: repeated, from: nested)
        var plugin = ExternalPlugin(classID: String(repeating: "A", count: 32), name: "Kontakt", path: "/Library/Audio/Plug-Ins/VST3/Kontakt.vst3", category: "Instrument")
        plugin.componentState = Data([0, 1, 255, 128, 0, 42]).base64EncodedString()
        plugin.controllerState = Data([7, 0, 255]).base64EncodedString(); plugin.bypassed = true
        fx.externalPlugins = [plugin]; fx.inserted.append(plugin.effectKey); track.fx = fx
        var automation = TrackAutomation(); automation.mode = .latch; automation.lanesVisible = true
        var volume = TrackEnvelope(target: AutomationTarget(.volume), name: "Volume", defaultValue: 0.4)
        volume.points = [EnvelopePoint(time: 0, value: 0.1), EnvelopePoint(time: 10, value: 0.9, shape: .smooth)]
        var eq = TrackEnvelope(target: AutomationTarget(.nativeFX, native: NativeFXParameter(effect: repeated, key: .bandGain, band: nested.bands[1].id, name: "Gain", range: -24...24)), name: "EQ", defaultValue: 0.3)
        eq.points = [EnvelopePoint(time: 3, value: 0.8)]; eq.armed = true
        let external = TrackEnvelope(target: AutomationTarget(.externalFX, plugin: plugin.id, parameter: 42), name: "Kontakt parameter", defaultValue: 0.6)
        automation.envelopes = [volume, eq, external]; track.automation = automation
        var clip = AudioClip(id: UUID(), name: "Take", startTime: 5, duration: 10, sourceOffset: 2, waveform: [0.1, 0.3], audioFile: AudioFile(path: "Stems/piano.wav"), gain: 0.4, phaseInverted: true, pan: 0.3)
        clip.normalizationGain = 1.2; clip.fadeIn = 1; clip.fadeOut = 2; clip.fadeInCurve = -0.5; clip.fadeOutSCurve = 0.75
        clip.waveformChannels = [[0.1, 0.3], [0.2, 0.6]]; clip.playbackRate = 1.2; clip.loopStart = 1; clip.loopLength = 4
        clip.fx = fx; clip.fxBypassed = true; clip.automation = automation; clip.automationSourceOffset = 0.5
        clip.frozenMIDI = true
        let region = Part(id: UUID(), name: "Song", startTime: 0, endTime: 60)
        clip.regionOwnerID = region.id
        var midi = AudioClip(id: UUID(), name: "MIDI", startTime: 20, duration: 5)
        midi.midi = MIDIItem(notes: [MIDINote(start: 0, length: 2, pitch: 60, velocity: 99, channel: 3)])
        midi.fadeIn = 0.2; midi.fadeOut = 0.7; midi.loopLength = 2
        track.clips = [clip, midi]
        project.songs[0].duration = 60; project.songs[0].tracks = [track]; project.songs[0].parts = [region]
        return project
    }

    func testCompleteIndependentCopyPreservesItemsAutomationAndOpaquePluginState() throws {
        var project = fixture(); try project.validate()
        let original = project.songs[0].tracks[0]
        let ids = try project.duplicateTracks([original.id], song: project.songs[0].id)
        XCTAssertEqual(ids.count, 1); XCTAssertEqual(project.songs[0].tracks[0], original)
        let copy = project.songs[0].tracks[1]
        XCTAssertTrue(ids.contains(copy.id)); XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.name, original.name); XCTAssertEqual(copy.role, original.role)
        XCTAssertEqual(copy.volume, original.volume); XCTAssertEqual(copy.pan, original.pan)
        XCTAssertEqual(copy.instrumentIcon, original.instrumentIcon); XCTAssertEqual(copy.color, original.color); XCTAssertEqual(copy.heightScale, original.heightScale)
        XCTAssertEqual(copy.phaseInverted, original.phaseInverted); XCTAssertEqual(copy.mute, original.mute); XCTAssertEqual(copy.solo, original.solo)
        XCTAssertEqual(copy.midiInput, original.midiInput); XCTAssertEqual(copy.midiChannel, original.midiChannel)
        XCTAssertEqual(copy.inputMonitoring, original.inputMonitoring); XCTAssertEqual(copy.inputPatch, original.inputPatch)
        XCTAssertEqual(copy.outputs, original.outputs); XCTAssertEqual(copy.recordingChannels, original.recordingChannels); XCTAssertEqual(copy.recordingFormat, original.recordingFormat)
        assertFXCopy(copy.fx!, original.fx!); assertAutomationCopy(copy.automation!, original.automation!, newFX: copy.fx!, oldFX: original.fx!)
        var expectedItem = original.clips[0], item = copy.clips[0]
        XCTAssertNotEqual(item.id, expectedItem.id)
        assertFXCopy(item.fx!, expectedItem.fx!); assertAutomationCopy(item.automation!, expectedItem.automation!, newFX: item.fx!, oldFX: expectedItem.fx!)
        expectedItem.id = item.id; expectedItem.fx = item.fx; expectedItem.automation = item.automation
        XCTAssertEqual(item, expectedItem, "All timing, audio, fades, MIDI and media fields travel with the item")
        var expectedMIDI = original.clips[1]
        XCTAssertNotEqual(copy.clips[1].id, expectedMIDI.id); XCTAssertNotEqual(copy.clips[1].midi!.notes[0].id, expectedMIDI.midi!.notes[0].id)
        expectedMIDI.id = copy.clips[1].id; expectedMIDI.midi!.notes[0].id = copy.clips[1].midi!.notes[0].id
        XCTAssertEqual(copy.clips[1], expectedMIDI)
        item.gain = 0.1
        project.songs[0].tracks[1].clips[0] = item
        project.songs[0].tracks[1].fx!.bands[2].gain = 8
        project.songs[0].tracks[1].automation!.envelopes[0].points[0].value = 0.5
        XCTAssertEqual(project.songs[0].tracks[0], original)
        XCTAssertEqual(project.mediaPaths, ["Stems/piano.wav"])
        let encoded = try JSONEncoder().encode(project)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: encoded), project)
    }

    private func assertFXCopy(_ copied: NativeFXSettings, _ original: NativeFXSettings, file: StaticString = #filePath, line: UInt = #line) {
        var restored = copied
        XCTAssertNotEqual(copied.bands[0].id, original.bands[0].id, file: file, line: line)
        for i in original.bands.indices { restored.bands[i].id = original.bands[i].id }
        for i in (original.instances ?? []).indices {
            XCTAssertNotEqual(copied.instances![i].id, original.instances![i].id, file: file, line: line)
            restored.instances![i].id = original.instances![i].id
            for band in original.instances![i].settings.bands.indices { restored.instances![i].settings.bands[band].id = original.instances![i].settings.bands[band].id }
        }
        for i in (original.externalPlugins ?? []).indices {
            XCTAssertNotEqual(copied.externalPlugins![i].id, original.externalPlugins![i].id, file: file, line: line)
            restored.externalPlugins![i].id = original.externalPlugins![i].id
        }
        restored.inserted = original.inserted
        XCTAssertEqual(restored, original, "Only instance identities change; opaque states and parameters remain exact", file: file, line: line)
    }
    private func assertAutomationCopy(_ copy: TrackAutomation, _ original: TrackAutomation, newFX: NativeFXSettings, oldFX: NativeFXSettings, file: StaticString = #filePath, line: UInt = #line) {
        var restored = copy
        for i in original.envelopes.indices {
            XCTAssertNotEqual(copy.envelopes[i].id, original.envelopes[i].id, file: file, line: line)
            restored.envelopes[i].id = original.envelopes[i].id
            for point in original.envelopes[i].points.indices {
                XCTAssertNotEqual(copy.envelopes[i].points[point].id, original.envelopes[i].points[point].id, file: file, line: line)
                restored.envelopes[i].points[point].id = original.envelopes[i].points[point].id
            }
            restored.envelopes[i].target = original.envelopes[i].target
        }
        XCTAssertEqual(restored, original, file: file, line: line)
        XCTAssertEqual(copy.envelopes[1].target.native?.effect, newFX.instances![0].effectKey, file: file, line: line)
        XCTAssertEqual(copy.envelopes[1].target.native?.band, newFX.instances![0].settings.bands[1].id, file: file, line: line)
        XCTAssertEqual(copy.envelopes[2].target.plugin, newFX.externalPlugins![0].id, file: file, line: line)
    }

    func testFolderCopiesDescendantsRoutesAndRegionRulesAfterWholeTree() throws {
        var project = fixture(); let folder = project.songs[0].tracks[0]
        var child = Track(id: UUID(), name: "Child", role: .keys); child.parentTrackID = folder.id
        var nested = Track(id: UUID(), name: "Nested", role: .other); nested.parentTrackID = folder.id
        var leaf = Track(id: UUID(), name: "Leaf", role: .bass); leaf.parentTrackID = nested.id
        var source = Track(id: UUID(), name: "External sender", role: .other)
        var bus = Track(id: UUID(), name: "External receiver", role: .other)
        source.routing = TrackRouting(transmitters: [leaf.id]); bus.routing = TrackRouting(receives: [folder.id])
        project.songs[0].tracks = [folder, child, nested, leaf, source, bus]
        project.songs[0].parts[0].pitchTrackIDs = [child.id]; project.songs[0].parts[0].pitchGroupIDs = [folder.id]
        let markers = [TimelineMarker(id: UUID(), name: "A", position: 2, color: 0xffffff), TimelineMarker(id: UUID(), name: "B", position: 12, color: 0xffffff)]
        project.songs[0].markers = markers
        var loop = MultiLoop(name: "Loop", marker1: markers[0].id, marker2: markers[1].id)
        var rule = MultiLoopTrack(id: child.id, gain: 0.4); rule.mute = true; rule.autoFader = true
        loop.tracks = [rule]; project.songs[0].parts[0].multiLoops = [loop]
        let ids = try project.duplicateTracks([folder.id, child.id], song: project.songs[0].id)
        XCTAssertEqual(ids.count, 4)
        let tracks = project.songs[0].tracks
        XCTAssertEqual(Array(tracks.prefix(4)), [folder, child, nested, leaf]); XCTAssertEqual(Array(tracks.suffix(2)), [source, bus])
        XCTAssertEqual(tracks[5].parentTrackID, tracks[4].id); XCTAssertEqual(tracks[6].parentTrackID, tracks[4].id); XCTAssertEqual(tracks[7].parentTrackID, tracks[6].id)
        XCTAssertTrue(tracks[4].routing?.transmitters.contains(bus.id) == true)
        XCTAssertTrue(tracks[7].routing?.receives.contains(source.id) == true)
        XCTAssertEqual(project.songs[0].parts[0].pitchTrackIDs, [child.id, tracks[5].id])
        XCTAssertEqual(project.songs[0].parts[0].pitchGroupIDs, [folder.id, tracks[4].id])
        rule.id = tracks[5].id
        XCTAssertEqual(project.songs[0].parts[0].multiLoops?[0].tracks, [loop.tracks[0], rule])
        try project.validate()
    }

    func testSelectedChildRemainsInsideOriginalFolder() throws {
        var project = fixture(); let folder = project.songs[0].tracks[0]
        var child = Track(id: UUID(), name: "Child", role: .keys); child.parentTrackID = folder.id
        var sibling = Track(id: UUID(), name: "Sibling", role: .keys); sibling.parentTrackID = folder.id
        let tail = Track(id: UUID(), name: "Tail", role: .keys)
        project.songs[0].tracks = [folder, child, sibling, tail]
        let ids = try project.duplicateTracks([child.id], song: project.songs[0].id)
        XCTAssertEqual(ids, [project.songs[0].tracks[2].id])
        XCTAssertEqual(project.songs[0].tracks[2].parentTrackID, folder.id)
        XCTAssertEqual(project.songs[0].tracks[3], sibling); XCTAssertEqual(project.songs[0].tracks[4], tail)
        try project.validate()
    }

    func testStereoSelectionCopiesCompletePairWithIndependentPartnerReferences() throws {
        var project = Project.empty(name: "Stereo")
        let left = Track(id: UUID(), name: "Left", role: .other), right = Track(id: UUID(), name: "Right", role: .other)
        project.songs[0].tracks = [left, right]
        project.songs[0].linkTracks([left.id, right.id], firstInput: 1, color: 0x123456)
        let original = project.songs[0].tracks
        let ids = try project.duplicateTracks([left.id], song: project.songs[0].id)
        XCTAssertEqual(ids.count, 2); XCTAssertEqual(Array(project.songs[0].tracks.prefix(2)), original)
        let copied = Array(project.songs[0].tracks.suffix(2))
        XCTAssertEqual(copied[0].stereoLink?.partner, copied[1].id); XCTAssertEqual(copied[1].stereoLink?.partner, copied[0].id)
        project.songs[0].unlinkTracks(copied[0].id)
        XCTAssertEqual(project.songs[0].tracks[2].name, left.name); XCTAssertEqual(Array(project.songs[0].tracks.prefix(2)), original)
    }

    func testMasterAndSpecialLanesCannotBeDuplicated() throws {
        var project = Project.empty(name: "Special")
        project.songs[0].tracks = TrackKind.allCases.filter { $0 != .standard }.map { Track(id: UUID(), name: $0.title, role: TrackRole(rawValue: $0.rawValue)) }
        let original = project
        let ids = Set(project.songs[0].tracks.map(\.id)).union([MultiLoopTrack.masterID, UUID()])
        XCTAssertTrue(try project.duplicateTracks(ids, song: project.songs[0].id).isEmpty)
        XCTAssertEqual(project, original)
    }

    @MainActor func testControllerCapturesLiveTrackAndItemStatesAndUndoRestoresSingleCopyEdit() throws {
        let executor = TrackCopyExecutor(), original = fixture()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: original)
        let track = original.songs[0].tracks[0], plugin = track.fx!.externalPlugins![0].id
        var captures: [UUID] = []
        show.prepareForFXChange = { target, clip, effects in
            XCTAssertTrue(effects.contains("External:" + plugin)); captures.append(clip ?? target!)
            _ = try show.storeCapturedPluginState(target, clip: clip, identifier: plugin, componentState: "AP8AAQ==", controllerState: "AAAAAA==")
        }
        let transport = show.snapshot.transport
        let copied = show.duplicateTracks([track.id])
        XCTAssertEqual(captures, [track.id, track.clips[0].id]); XCTAssertEqual(copied.count, 1)
        let duplicated = try XCTUnwrap(show.current).tracks[1]
        XCTAssertEqual(duplicated.fx?.externalPlugins?[0].componentState, "AP8AAQ==")
        XCTAssertEqual(duplicated.clips[0].fx?.externalPlugins?[0].controllerState, "AAAAAA==")
        XCTAssertEqual(show.mixerTrackSelection, copied); XCTAssertEqual(show.snapshot.transport, transport)
        show.undo()
        XCTAssertEqual(show.current?.tracks.count, 1)
        XCTAssertEqual(show.current?.tracks[0].fx?.externalPlugins?[0].componentState, "AP8AAQ==", "Undo duplication keeps live source state")
        show.redo()
        XCTAssertEqual(show.current?.tracks[1], duplicated); XCTAssertEqual(show.snapshot.transport, transport)
    }

    @MainActor func testFailedPluginCaptureNeverInsertsPartialTrackCopies() throws {
        let executor = TrackCopyExecutor(), original = fixture()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: original)
        show.prepareForFXChange = { _, _, _ in throw ProjectError.invalid("Plugin did not provide its state") }
        XCTAssertTrue(show.duplicateTracks([original.songs[0].tracks[0].id]).isEmpty)
        XCTAssertEqual(show.snapshot.project, original); XCTAssertEqual(executor.edits, 0)
        XCTAssertFalse(show.message.isEmpty)
    }
}
