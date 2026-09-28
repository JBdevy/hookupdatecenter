import XCTest
@testable import JarasApplication

@MainActor private final class IncrementalSettingsExecutor: CommandExecutor {
    struct GainCommand: Equatable { let item: UUID; let value: Double }
    var project = Project.empty(name: "Incremental")
    var transport = TransportState(playing: true, position: 37.5, editPosition: 32, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false,position: 75))
    var snapshotReads = 0, playbackReads = 0, fullEdits = 0
    var settingsCommands: [String] = []
    var gainCommands: [GainCommand] = []
    var mixerCommands: [ShowCommand] = []
    var failGainCommand: Int?
    var failMixerCommand: ShowCommand?
    var failSettingsCommand: String?
    func load(_ project: Project) throws {
        try project.validate(); self.project = project
        transport.songId = project.songs.first?.id; transport.regionId = project.songs.first?.parts.first?.id
    }
    func snapshot() throws -> ShowSnapshot {
        snapshotReads += 1
        return ShowSnapshot(project: project,transport: transport)
    }
    func playbackSnapshot() throws -> PlaybackSnapshot { playbackReads += 1; return PlaybackSnapshot(transport: transport) }
    func applyProjectEdit(_ project: Project) throws { try project.validate(); self.project = project; fullEdits += 1 }
    func execute(_ command: ShowCommand,target: UUID?,value: Double) throws {
        if command != .clipGain {
            mixerCommands.append(command)
            if failMixerCommand == command { throw ProjectError.invalid("Injected mixer failure") }
            if target == nil {
                if command == .volume { project.masterVolume = min(pow(10,12.0 / 20),max(0,value)) }
                else if command == .mute { project.masterMute = !(project.masterMute ?? false) }
                else { XCTFail("Unexpected master command: \(command)") }
                return
            }
            for song in project.songs.indices {
                for track in project.songs[song].tracks.indices {
                    if command == .clipMute, let clip = project.songs[song].tracks[track].clips.firstIndex(where: { $0.id == target }) {
                        project.songs[song].tracks[track].clips[clip].muted = !(project.songs[song].tracks[track].clips[clip].muted ?? false); return
                    }
                    guard project.songs[song].tracks[track].id == target else { continue }
                    switch command {
                    case .volume: project.songs[song].tracks[track].volume = min(pow(10,12.0 / 20),max(0,value))
                    case .pan: project.songs[song].tracks[track].pan = min(1,max(-1,value))
                    case .mute: project.songs[song].tracks[track].mute.toggle()
                    case .solo: project.songs[song].tracks[track].solo.toggle()
                    default: XCTFail("Unexpected track command: \(command)")
                    }
                    return
                }
            }
            throw ProjectError.invalid("Missing mixer target")
        }
        guard let target else { XCTFail("Missing gain target"); return }
        gainCommands.append(GainCommand(item: target,value: value))
        if failGainCommand == gainCommands.count { throw ProjectError.invalid("Injected gain failure") }
        for song in project.songs.indices {
            for track in project.songs[song].tracks.indices {
                if let clip = project.songs[song].tracks[track].clips.firstIndex(where: { $0.id == target }) {
                    project.songs[song].tracks[track].clips[clip].gain = value; return
                }
            }
        }
        throw ProjectError.invalid("Missing clip")
    }
    private func mutate(_ id: UUID,operation: String,edit: (inout Track) -> Void) throws {
        settingsCommands.append(operation)
        if failSettingsCommand == operation { throw ProjectError.invalid("Injected settings failure") }
        for song in project.songs.indices {
            if let track = project.songs[song].tracks.firstIndex(where: { $0.id == id }) {
                edit(&project.songs[song].tracks[track]); return
            }
        }
        throw ProjectError.invalid("Missing track")
    }
    func setTimecode(_ track: UUID,settings: TimecodeSettings) throws {
        try settings.validate()
        try mutate(track,operation: "timecode") { value in
            value.timecode = settings
            for clip in value.clips.indices { value.clips[clip].name = "TIMECODE" }
        }
    }
    func editTrack(_ track: UUID,name: String,color: UInt32) throws { try mutate(track,operation: "details") { $0.name = name; $0.color = color } }
    func editRegion(_ id: UUID,name: String,color: UInt32,uppercaseName: Bool) throws {
        settingsCommands.append("region")
        for song in project.songs.indices {
            if let part = project.songs[song].parts.firstIndex(where: { $0.id == id }) {
                project.songs[song].parts[part].name = name; project.songs[song].parts[part].color = color; project.songs[song].parts[part].uppercaseName = uppercaseName; return
            }
        }
        throw ProjectError.invalid("Missing region")
    }
    func setMIDIInput(_ track: UUID,slot: Int) throws { try mutate(track,operation: "midi") { $0.midiInput = slot == 0 ? nil : slot } }
    func setRecording(_ track: UUID,input: OutputPatch,format: String) throws { try mutate(track,operation: "recording") { $0.inputPatch = input; $0.recordingFormat = format } }
    func setOutputPatch(track: UUID?,patch: OutputPatch,slot: Int) throws {
        if let track {
            try mutate(track,operation: "output") { if slot == 0 { $0.patch = patch } else { $0.secondaryPatch = patch } }
        } else {
            settingsCommands.append("masterOutput")
            if failSettingsCommand == "masterOutput" { throw ProjectError.invalid("Injected settings failure") }
            if slot == 0 { project.masterPatch = patch } else { project.masterSecondaryPatch = patch }
        }
    }
    func deleteManualMarker(_ id: UUID) throws {
        settingsCommands.append("deleteMarker")
        guard let song = project.songs.firstIndex(where: { $0.id == transport.songId }),
              let marker = project.songs[song].markers?.first(where: { $0.id == id }),
              marker.unifiedRegionID == nil, marker.sourceRegionID == nil else { throw ProjectError.invalid("Protected marker") }
        project.songs[song].markers?.removeAll { $0.id == id }
    }
    func addTrack(id: UUID,name: String,role: TrackRole) throws { XCTFail("Unexpected addTrack") }
    func advance(_ elapsed: Double) {}
    func finishCurrentSong(_ enabled: Bool) {}
}

final class IncrementalTrackSettingsTests: XCTestCase {
    @MainActor func testManualMarkerDeleteDoesNotReloadAudioAndUndoRestoresIt() throws {
        var project = fixture()
        let manual = TimelineMarker(id: UUID(), name: "Manual", position: 35, color: 0x00ff88)
        let protected = TimelineMarker(id: UUID(), name: "Song", position: 40, color: 0xffcc00, unifiedRegionID: project.songs[0].parts[0].id)
        project.songs[0].markers = [manual, protected]
        let (show, executor) = try show(project)
        let reads = executor.snapshotReads
        var revisions: [UInt64] = []
        show.audioUpdate = { _, revision in revisions.append(revision) }
        show.preparePlayback()
        let revision = try XCTUnwrap(revisions.last)
        let transport = show.snapshot.transport
        show.deleteManualMarker(protected.id)
        XCTAssertTrue(executor.settingsCommands.isEmpty)
        show.deleteManualMarker(manual.id)
        XCTAssertEqual(show.current?.markers, [protected])
        XCTAssertEqual(executor.settingsCommands, ["deleteMarker"])
        XCTAssertEqual(executor.fullEdits, 0)
        XCTAssertEqual(executor.snapshotReads, reads)
        XCTAssertEqual(revisions.last, revision)
        XCTAssertEqual(show.snapshot.transport, transport)
        XCTAssertTrue(show.hasUnsavedChanges)
        show.undo()
        XCTAssertEqual(show.current?.markers, [manual, protected])
        show.redo()
        XCTAssertEqual(show.current?.markers, [protected])
    }
    private enum AudioEdit: Equatable {
        case volume(UUID?,Double), pan(UUID,Double), mute(UUID?,Bool), solo(UUID,Bool), clipMute(UUID,Bool)
        case midi(UUID,Int), patch(UUID?,OutputPatch,Int)
    }
    private func fixture() -> Project {
        var project = Project.empty(name: "Incremental settings")
        let region = Part(id: UUID(),name: "Song",startTime: 30,endTime: 60)
        var timecode = Track(id: UUID(),name: "Timecode",role: TrackRole(rawValue: "timecode"))
        timecode.timecode = TimecodeSettings(); timecode.patch = OutputPatch.none
        timecode.clips = [AudioClip(id: Project.timecodeItemID(region.id),name: "TIMECODE",startTime: 30,duration: 30)]
        var audio = Track(id: UUID(),name: "Keys",role: .keys)
        let waveform = (0..<4096).map { Double($0 % 64) / 64 }
        audio.clips = [
            AudioClip(id: UUID(),name: "Stereo",startTime: 30,duration: 20,waveform: waveform,audioFile: AudioFile(path: "Steams/stereo.wav"),gain: 1,waveformChannels: [waveform,waveform.reversed().map { $0 }]),
            AudioClip(id: UUID(),name: "Mono",startTime: 50,duration: 10,waveform: waveform,audioFile: AudioFile(path: "Steams/mono.wav"),gain: 0.75)
        ]
        project.songs[0].parts = [region]; project.songs[0].tracks = [timecode,audio]
        project.songs[0].duration = 120
        return project
    }
    @MainActor private func show(_ project: Project) throws -> (ShowController,IncrementalSettingsExecutor) {
        let executor = IncrementalSettingsExecutor()
        let show = try ShowController(executor: executor,persistence: MemoryProjectStore(),initialProject: project)
        executor.snapshotReads = 0; executor.playbackReads = 0
        return (show,executor)
    }
    @MainActor func testTimecodeModeEditsRetainAudioRevisionTransportAndWaveformStorageWithoutReads() throws {
        let project = fixture(), (show,executor) = try show(project)
        let originalTransport = show.snapshot.transport
        let originalAudio = project.songs[0].tracks[1]
        let originalWave = originalAudio.clips[0].waveform.withUnsafeBufferPointer { $0.baseAddress }
        var revisions: [UInt64] = []
        show.audioUpdate = { snapshot,revision in
            revisions.append(revision); XCTAssertEqual(snapshot.transport,originalTransport)
        }
        var settings = TimecodeSettings(); settings.mode = "ltc"; settings.frameRate = 25
        show.setTimecode(project.songs[0].tracks[0].id,settings: settings)
        settings.mode = "mtc"
        show.setTimecode(project.songs[0].tracks[0].id,settings: settings)
        show.setTimecode(project.songs[0].tracks[0].id,settings: settings)
        XCTAssertEqual(executor.settingsCommands,["timecode","timecode"])
        XCTAssertEqual(executor.snapshotReads,0); XCTAssertEqual(executor.playbackReads,0); XCTAssertEqual(executor.fullEdits,0)
        XCTAssertEqual(revisions,[0,0]); XCTAssertEqual(show.projectRevision,2)
        XCTAssertEqual(show.snapshot.transport,originalTransport)
        XCTAssertEqual(show.current?.tracks[1],originalAudio)
        XCTAssertEqual(show.current?.tracks[1].clips[0].waveform.withUnsafeBufferPointer { $0.baseAddress },originalWave)
        XCTAssertEqual(show.current?.tracks[0].timecode,settings)
        XCTAssertEqual(show.current?.tracks[0].clips,project.songs[0].tracks[0].clips)
        XCTAssertTrue(show.canUndo); XCTAssertTrue(show.hasUnsavedChanges)
    }
    @MainActor func testTrackDetailsMIDIRecordingAndRoutingUseIncrementalSettingsWithoutSnapshot() throws {
        let project = fixture(), (show,executor) = try show(project)
        let track = project.songs[0].tracks[1].id, originalClips = project.songs[0].tracks[1].clips
        let originalTransport = show.snapshot.transport
        var revisions: [UInt64] = []
        var callbacks: [AudioEdit] = []
        show.audioUpdate = { _,revision in revisions.append(revision) }
        show.audioMIDIInput = { callbacks.append(.midi($0,$1)) }
        show.audioPatch = { callbacks.append(.patch($0,$1,$2)) }
        show.editTrack(track,name: "Piano",color: 0x12ab34)
        show.editTrack(track,name: "Piano",color: 0x12ab34)
        let input = OutputPatch(firstChannel: 3,channelCount: 1)
        show.setRecording(track,input: input,format: "wav32")
        show.setRecording(track,input: input,format: "wav32")
        show.setMIDIInput(track,slot: 2); show.setMIDIInput(track,slot: 2)
        show.setOutputPatch(track: track,patch: OutputPatch(firstChannel: 5,channelCount: 2),slot: 1)
        show.setOutputPatch(track: track,patch: OutputPatch(firstChannel: 5,channelCount: 2),slot: 1)
        show.setOutputPatch(track: nil,patch: OutputPatch(firstChannel: 7,channelCount: 2),slot: 0)
        show.setOutputPatch(track: nil,patch: OutputPatch(firstChannel: 7,channelCount: 2),slot: 0)
        let region = project.songs[0].parts[0].id
        show.editRegion(region,name: "New region",color: 0xabcdef)
        show.editRegion(region,name: "New region",color: 0xabcdef)
        XCTAssertEqual(executor.settingsCommands,["details","recording","midi","output","masterOutput","region"])
        XCTAssertEqual(executor.snapshotReads,0); XCTAssertEqual(executor.playbackReads,0); XCTAssertEqual(executor.fullEdits,0)
        XCTAssertEqual(revisions,[0,0,0,0,0,0]); XCTAssertEqual(show.projectRevision,6)
        XCTAssertEqual(callbacks,[.midi(track,2),.patch(track,OutputPatch(firstChannel: 5,channelCount: 2),1),.patch(nil,OutputPatch(firstChannel: 7,channelCount: 2),0)])
        XCTAssertEqual(show.snapshot.transport,originalTransport); XCTAssertEqual(show.current?.tracks[1].clips,originalClips)
        XCTAssertEqual(show.snapshot.project,executor.project)
        XCTAssertEqual(show.current?.tracks[1].name,"Piano"); XCTAssertEqual(show.current?.tracks[1].inputPatch,input)
        XCTAssertEqual(show.current?.tracks[1].midiInput,2)
    }
    @MainActor func testRejectedScalarSettingsLeaveControllerAndHistoryUnchanged() throws {
        let project = fixture(), (show,executor) = try show(project)
        let timecode = project.songs[0].tracks[0].id
        var settings = TimecodeSettings(); settings.mode = "ltc"
        executor.failSettingsCommand = "timecode"
        show.setTimecode(timecode,settings: settings)
        settings.mode = "invalid"; show.setTimecode(timecode,settings: settings)
        let track = project.songs[0].tracks[1].id
        var callbacks: [AudioEdit] = [], audioUpdates = 0
        show.audioMIDIInput = { callbacks.append(.midi($0,$1)) }
        show.audioPatch = { callbacks.append(.patch($0,$1,$2)) }
        show.audioMute = { callbacks.append(.mute($0,$1)) }
        show.audioUpdate = { _,_ in audioUpdates += 1 }
        executor.failSettingsCommand = "midi"; show.setMIDIInput(track,slot: 2)
        executor.failSettingsCommand = "output"; show.setOutputPatch(track: track,patch: .stereo)
        executor.failSettingsCommand = "recording"; show.setRecording(track,input: .stereo,format: "wav32")
        executor.failSettingsCommand = "details"; show.editTrack(track,name: "New name",color: 0xabcdef)
        executor.failMixerCommand = .mute; show.send(.mute,target: track)
        XCTAssertEqual(executor.settingsCommands,["timecode","midi","output","recording","details"])
        XCTAssertTrue(callbacks.isEmpty); XCTAssertEqual(audioUpdates,0)
        XCTAssertEqual(show.snapshot.project,project); XCTAssertEqual(executor.project,project)
        XCTAssertFalse(show.hasUnsavedChanges); XCTAssertFalse(show.canUndo); XCTAssertEqual(show.projectRevision,0)
        XCTAssertEqual(executor.snapshotReads,0); XCTAssertEqual(executor.fullEdits,0)
        XCTAssertFalse(show.message.isEmpty)
    }
    @MainActor func testMixerEditsDeliverExactScalarAudioCallbacksWithoutAudioRevisionOrTransportChange() throws {
        let project = fixture(), (show,executor) = try show(project)
        let track = project.songs[0].tracks[1].id, clip = project.songs[0].tracks[1].clips[0].id
        let originalTransport = show.snapshot.transport
        var callbacks: [AudioEdit] = [], revisions: [UInt64] = []
        show.audioVolume = { callbacks.append(.volume($0,$1)) }
        show.audioPan = { callbacks.append(.pan($0,$1)) }
        show.audioMute = { callbacks.append(.mute($0,$1)) }
        show.audioSolo = { callbacks.append(.solo($0,$1)) }
        show.audioClipMute = { callbacks.append(.clipMute($0,$1)) }
        show.audioUpdate = { _,revision in revisions.append(revision) }
        show.send(.volume,target: track,value: 0.4)
        show.send(.pan,target: track,value: 2)
        show.send(.mute,target: track)
        show.send(.solo,target: track)
        show.send(.clipMute,target: clip)
        show.send(.volume,value: 0.65)
        show.send(.mute)
        show.send(.mute,target: track)
        XCTAssertEqual(callbacks,[.volume(track,0.4),.pan(track,1),.mute(track,true),.solo(track,true),.clipMute(clip,true),.volume(nil,0.65),.mute(nil,true),.mute(track,false)])
        XCTAssertEqual(executor.mixerCommands,[.volume,.pan,.mute,.solo,.clipMute,.volume,.mute,.mute])
        XCTAssertEqual(revisions,Array(repeating: 0,count: 8)); XCTAssertEqual(show.projectRevision,8)
        XCTAssertEqual(executor.snapshotReads,0); XCTAssertEqual(executor.playbackReads,0); XCTAssertEqual(executor.fullEdits,0)
        XCTAssertEqual(show.snapshot.transport,originalTransport); XCTAssertEqual(show.snapshot.project,executor.project)
        XCTAssertEqual(show.current?.tracks[1].clips[0].waveform,project.songs[0].tracks[1].clips[0].waveform)
    }
    @MainActor func testNormalizationCommitsScalarBatchOnceAndUndoRestoresWholeBatch() throws {
        let project = fixture(), (show,executor) = try show(project)
        let clips = project.songs[0].tracks[1].clips
        let capped = pow(10,12.0 / 20)
        var gains: [IncrementalSettingsExecutor.GainCommand] = [], revisions: [UInt64] = []
        show.audioItemGain = { gains.append(.init(item: $0,value: $1)) }
        show.audioUpdate = { _,revision in revisions.append(revision) }
        XCTAssertTrue(show.normalizeItems([clips[0].id: 100,clips[1].id: 0.25],project: project.id))
        let expected: [IncrementalSettingsExecutor.GainCommand] = [.init(item: clips[0].id,value: capped),.init(item: clips[1].id,value: 0.25)]
        XCTAssertEqual(executor.gainCommands,expected); XCTAssertEqual(gains,expected)
        XCTAssertEqual(executor.snapshotReads,0); XCTAssertEqual(executor.playbackReads,0); XCTAssertEqual(executor.fullEdits,0)
        XCTAssertEqual(revisions,[0]); XCTAssertEqual(show.projectRevision,1); XCTAssertTrue(show.canUndo)
        XCTAssertEqual(show.current?.tracks[1].clips[0].waveform,clips[0].waveform)
        XCTAssertEqual(show.current?.tracks[1].clips[0].waveformChannels,clips[0].waveformChannels)
        show.undo()
        XCTAssertEqual(show.snapshot.project,project); XCTAssertFalse(show.canUndo); XCTAssertTrue(show.canRedo)
        show.redo()
        XCTAssertEqual(show.current?.tracks[1].clips.map { $0.gain ?? 1 },[capped,0.25])
        XCTAssertEqual(executor.fullEdits,2)
    }
    @MainActor func testFailedNormalizationRollsBackAppliedScalarsWithoutPublishingOrUndo() throws {
        let project = fixture(), (show,executor) = try show(project)
        let clips = project.songs[0].tracks[1].clips
        executor.failGainCommand = 2
        var audioWrites = 0, audioUpdates = 0
        show.audioItemGain = { _,_ in audioWrites += 1 }; show.audioUpdate = { _,_ in audioUpdates += 1 }
        XCTAssertFalse(show.normalizeItems([clips[0].id: 0.5,clips[1].id: 0.25],project: project.id))
        XCTAssertEqual(executor.gainCommands,[.init(item: clips[0].id,value: 0.5),.init(item: clips[1].id,value: 0.25),.init(item: clips[0].id,value: 1)])
        XCTAssertEqual(show.snapshot.project,project); XCTAssertEqual(executor.project,project)
        XCTAssertEqual(audioWrites,0); XCTAssertEqual(audioUpdates,0); XCTAssertEqual(show.projectRevision,0)
        XCTAssertFalse(show.hasUnsavedChanges); XCTAssertFalse(show.canUndo)
        XCTAssertEqual(executor.snapshotReads,0); XCTAssertEqual(executor.fullEdits,0)
    }
    @MainActor func testNormalizationRejectsUnknownOrInvalidItemsBeforeAnyScalarAndAcceptsNoOp() throws {
        let project = fixture(), (show,executor) = try show(project)
        let clips = project.songs[0].tracks[1].clips
        XCTAssertFalse(show.normalizeItems([clips[0].id: 0.5,UUID(): 0.5],project: project.id))
        XCTAssertFalse(show.normalizeItems([clips[0].id: .nan],project: project.id))
        XCTAssertFalse(show.normalizeItems([clips[0].id: 0.5],project: UUID()))
        XCTAssertTrue(executor.gainCommands.isEmpty)
        XCTAssertTrue(show.normalizeItems([clips[0].id: 1,clips[1].id: 0.75],project: project.id))
        XCTAssertFalse(show.hasUnsavedChanges); XCTAssertFalse(show.canUndo); XCTAssertEqual(show.projectRevision,0)
        XCTAssertEqual(executor.snapshotReads,0); XCTAssertEqual(executor.fullEdits,0)
    }
    @MainActor func testActionsSelectTrackAndDeliverMIDIWithoutReloadingProject() throws {
        let project = fixture(), (show, executor) = try show(project)
        let track = project.songs[0].tracks[1].id
        let transport = show.snapshot.transport
        var audioRefreshes: [UInt64] = []; show.audioUpdate = { _, revision in audioRefreshes.append(revision) }
        show.performAction(.selectTrack, trackNumber: 2)
        let firstRequest = show.trackSelectionRequest
        XCTAssertEqual(firstRequest?.track, track)
        show.performAction(.selectTrack, trackNumber: 2)
        XCTAssertNotEqual(show.trackSelectionRequest?.id, firstRequest?.id)
        show.performAction(.muteTrack)
        show.performAction(.soloTrack)
        show.performAction(.volumeTrack, midiValue: 0)
        show.performAction(.panTrack, midiValue: 64)
        XCTAssertTrue(show.current!.tracks[1].mute)
        XCTAssertTrue(show.current!.tracks[1].solo)
        XCTAssertEqual(show.current!.tracks[1].volume, 0)
        XCTAssertEqual(show.current!.tracks[1].pan, 0)
        XCTAssertEqual(executor.snapshotReads, 0)
        XCTAssertEqual(executor.fullEdits, 0)
        XCTAssertEqual(Set(audioRefreshes), [0])
        XCTAssertEqual(show.snapshot.transport, transport)
        show.performAction(.addTrack)
        XCTAssertEqual(show.addTrackRequest, 1)
        show.performAction(.setlistDown)
        XCTAssertEqual(show.setlistNavigationRequest?.direction, 1)
        show.performAction(.setlistUp)
        XCTAssertEqual(show.setlistNavigationRequest?.direction, -1)
    }

}
