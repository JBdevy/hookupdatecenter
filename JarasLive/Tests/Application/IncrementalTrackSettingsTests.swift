import XCTest
import Combine
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
    var failSettingsCommandAt: Int?
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
        if command == .toggleMultiLoopBypass { transport.multiLoopsBypassed = !(transport.multiLoopsBypassed == true); return }
        if command != .clipGain && command != .clipNormalization && command != .clipChannelMode {
            mixerCommands.append(command)
            if failMixerCommand == command { throw ProjectError.invalid("Injected mixer failure") }
            if target == nil {
                if command == .volume { project.masterVolume = min(pow(10,12.0 / 20),max(0,value)) }
                else if command == .mute { project.masterMute = !(project.masterMute ?? false) }
                else if command == .solo { project.masterSolo = !(project.masterSolo ?? false) }
                else if command == .phase { project.masterPhaseInverted = !(project.masterPhaseInverted ?? false) }
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
                    case .phase: project.songs[song].tracks[track].phaseInverted = !(project.songs[song].tracks[track].phaseInverted ?? false)
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
                    if command == .clipChannelMode { project.songs[song].tracks[track].clips[clip].channelMode = value == 0 ? nil : Int(value) }
                    else if command == .clipNormalization { project.songs[song].tracks[track].clips[clip].normalizationGain = value == 1 ? nil : value }
                    else { project.songs[song].tracks[track].clips[clip].gain = value }; return
                }
            }
        }
        throw ProjectError.invalid("Missing clip")
    }
    private func mutate(_ id: UUID,operation: String,edit: (inout Track) -> Void) throws {
        settingsCommands.append(operation)
        if failSettingsCommand == operation || failSettingsCommandAt == settingsCommands.count { throw ProjectError.invalid("Injected settings failure") }
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
    func editMasterColor(_ color: UInt32) throws {
        settingsCommands.append("masterColor")
        if failSettingsCommand == "masterColor" { throw ProjectError.invalid("Injected settings failure") }
        project.masterColor = color
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
    func setMIDIChannel(_ track: UUID, channel: Int) throws {
        guard (0...16).contains(channel) else { throw ProjectError.invalid("Invalid MIDI channel") }
        try mutate(track, operation: "midiChannel") { $0.midiChannel = channel == 0 ? nil : channel }
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

private actor PresentationSaveStore: ProjectPersistence {
    private var saving: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func load() -> Project? { nil }
    func save(_ project: Project) async {
        await withCheckedContinuation { continuation in
            saving = continuation
            started?.resume(); started = nil
        }
    }
    func waitUntilSaving() async {
        guard saving == nil else { return }
        await withCheckedContinuation { started = $0 }
    }
    func completeSave() { saving?.resume(); saving = nil }
}

final class IncrementalTrackSettingsTests: XCTestCase {
    @MainActor func testMIDIChannelIsIncrementalAndFiltersEveryVoiceMessage() throws {
        let project = fixture(), (show, executor) = try show(project)
        let id = project.songs[0].tracks[1].id
        var received: [Int] = []
        show.audioMIDIChannel = { _, channel in received.append(channel) }
        show.setMIDIChannel(id, channel: 16); show.setMIDIChannel(id, channel: 16)
        let track = try XCTUnwrap(show.current?.tracks[1])
        XCTAssertEqual(track.midiChannel, 16)
        for kind: UInt8 in [0x80, 0x90, 0xb0, 0xe0] {
            XCTAssertTrue(track.acceptsMIDI(status: kind | 15))
            XCTAssertFalse(track.acceptsMIDI(status: kind))
        }
        XCTAssertEqual(try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(track)), track)
        XCTAssertEqual(received, [16]); XCTAssertEqual(executor.fullEdits, 0); XCTAssertEqual(executor.snapshotReads, 0)
        show.setMIDIChannel(id, channel: 17)
        XCTAssertEqual(show.current?.tracks[1].midiChannel, 16)
        show.setMIDIChannel(id, channel: 0)
        XCTAssertNil(show.current?.tracks[1].midiChannel)
        XCTAssertTrue(show.current!.tracks[1].acceptsMIDI(status: 0x91))
        XCTAssertFalse(show.current!.tracks[1].acceptsMIDI(status: 0xf8))
    }
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
            AudioClip(id: UUID(),name: "Stereo",startTime: 30,duration: 20,waveform: waveform,audioFile: AudioFile(path: "Stems/stereo.wav"),gain: 1,waveformChannels: [waveform,waveform.reversed().map { $0 }]),
            AudioClip(id: UUID(),name: "Mono",startTime: 50,duration: 10,waveform: waveform,audioFile: AudioFile(path: "Stems/mono.wav"),gain: 0.75)
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
    @MainActor func testGlobalBypassPersistsBothStatesAcrossProjectsAndControllerRestarts() throws {
        let suite = "catlive.bypass.test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let executor = IncrementalSettingsExecutor()
        let controller = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: fixture(), globalDefaults: defaults)
        XCTAssertFalse(controller.snapshot.transport.multiLoopsBypassed == true)
        controller.performAction(.toggleMultiLoopBypass)
        XCTAssertTrue(defaults.bool(forKey: ShowController.multiLoopBypassDefaultsKey))
        try controller.replaceProject(fixture())
        XCTAssertTrue(controller.snapshot.transport.multiLoopsBypassed == true)
        let reopened = try ShowController(executor: IncrementalSettingsExecutor(), persistence: MemoryProjectStore(), initialProject: fixture(), globalDefaults: defaults)
        XCTAssertTrue(reopened.snapshot.transport.multiLoopsBypassed == true)
        reopened.performAction(.toggleMultiLoopBypass)
        XCTAssertFalse(defaults.bool(forKey: ShowController.multiLoopBypassDefaultsKey))
        let off = try ShowController(executor: IncrementalSettingsExecutor(), persistence: MemoryProjectStore(), initialProject: fixture(), globalDefaults: defaults)
        XCTAssertFalse(off.snapshot.transport.multiLoopsBypassed == true)
    }
    @MainActor func testStaticPresentationIgnoresClockButKeepsControlAndRegionChanges() async throws {
        var project = fixture()
        let second = Part(id: UUID(), name: "Second", startTime: 60, endTime: 90)
        project.songs[0].parts.append(second)
        let (controller, executor) = try show(project)
        let observer = controller.presentationObserver
        let toolbarObserver = controller.presentationObserver
        XCTAssertTrue(observer === toolbarObserver, "Static controls must share their playback state derivation")
        var changes = 0, toolbarChanges = 0
        let subscription = observer.objectWillChange.sink { changes += 1 }
        let toolbarSubscription = toolbarObserver.objectWillChange.sink { toolbarChanges += 1 }
        defer { subscription.cancel(); toolbarSubscription.cancel() }
        func flush() async { await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } } }
        for step in 1...30 {
            executor.transport.position = 37.5 + Double(step) / 30
            controller.tick()
            await flush()
        }
        XCTAssertEqual(changes, 0, "Setlist and toolbar must not rebuild on playback samples")
        executor.transport.queuedRegionId = second.id
        executor.transport.queueStartedAt = executor.transport.position
        controller.tick(); await flush()
        XCTAssertEqual(changes, 1, "Arming the queue updates controls immediately on the next UI turn")
        executor.transport.position = 65
        controller.tick(); await flush()
        XCTAssertEqual(changes, 2, "Crossing a region updates titles even when regionId stays unchanged")
        executor.transport.subPlay.playing = true
        executor.transport.subPlay.position = 40
        controller.tick(); await flush()
        XCTAssertEqual(changes, 3)
        executor.transport.subPlay.position = 65
        controller.tick(); await flush()
        XCTAssertEqual(changes, 4, "SubPlay crossing a region must update its displayed song")
        let track = try XCTUnwrap(controller.current?.tracks.last?.id)
        controller.sendMixerControl(.mute, target: track)
        await flush()
        XCTAssertEqual(changes, 5)
        executor.transport.playing = false
        controller.tick(); await flush()
        XCTAssertEqual(changes, 6, "Stopping restores Play and disables Pause")
        controller.modalNotice = "A marker already exists at this position."
        await flush()
        XCTAssertEqual(changes, 7, "Modal notices still update without observing the playback clock")
        controller.modalNotice = nil
        await flush()
        XCTAssertEqual(changes, 8)
        controller.sendMixerControl(.volume, target: track, value: 0.5, preview: true)
        await flush()
        XCTAssertEqual(changes, 8, "Fader previews keep their direct audio update without redrawing static controls")
        controller.sendMixerControl(.volume, target: track, value: 0.5)
        await flush()
        XCTAssertEqual(changes, 9, "Committing the fader still publishes its project edit")
        XCTAssertEqual(controller.current?.tracks.last?.volume, 0.5)
        let region = try XCTUnwrap(controller.current?.parts.first)
        controller.editRegion(region.id, name: "Renamed", color: 0x44ff88)
        await flush()
        XCTAssertEqual(changes, 10, "Region metadata updates titles without a transport boundary change")
        XCTAssertEqual(controller.current?.parts.first?.name, "Renamed")
        controller.performAction(.toggleMultiLoopBypass)
        await flush()
        XCTAssertEqual(changes, 11)
        XCTAssertTrue(controller.snapshot.transport.multiLoopsBypassed == true)
        controller.performAction(.toggleMultiLoopBypass)
        await flush()
        XCTAssertEqual(changes, 12)
        XCTAssertFalse(controller.snapshot.transport.multiLoopsBypassed == true)
        XCTAssertEqual(toolbarChanges, changes, "Every control subscribed to the shared observer receives the same boundary and edit updates")
    }
    @MainActor func testSharedPresentationObserverReleasesWithoutRetainingController() throws {
        var controller: ShowController? = try show(fixture()).0
        weak var releasedController = controller
        var observer: ShowPresentationObserver? = controller?.presentationObserver
        weak var releasedObserver = observer
        XCTAssertTrue(observer === controller?.presentationObserver)
        observer = nil
        XCTAssertNil(releasedObserver, "The controller's cache must not retain a dismissed presentation observer")
        observer = controller?.presentationObserver
        releasedObserver = observer
        XCTAssertNotNil(observer, "A new presentation can recreate its released observer")
        controller = nil
        XCTAssertNotNil(releasedController, "A visible presentation retains its controller")
        observer = nil
        XCTAssertNil(releasedObserver)
        XCTAssertNil(releasedController, "The shared observer must not create a controller retain cycle")
    }
    @MainActor func testSharedPresentationPublishesSavingAndSavedStateToEveryControl() async throws {
        let store = PresentationSaveStore()
        let controller = try ShowController(executor: IncrementalSettingsExecutor(), persistence: store, initialProject: fixture())
        let observer = controller.presentationObserver
        let toolbarObserver = controller.presentationObserver
        var states: [ShowPresentationState] = [], toolbarStates: [ShowPresentationState] = []
        let subscription = observer.objectWillChange.sink { states.append(controller.presentationState) }
        let toolbarSubscription = toolbarObserver.objectWillChange.sink { toolbarStates.append(controller.presentationState) }
        defer { subscription.cancel(); toolbarSubscription.cancel() }
        func flush() async { await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } } }
        let save = Task { try await controller.flushProject() }
        await store.waitUntilSaving()
        await flush()
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states.last?.saving, true)
        await store.completeSave()
        try await save.value
        await flush()
        XCTAssertEqual(states.count, 2, "Save completion coalesces its saved timestamp, dirty flag and saving flag")
        XCTAssertEqual(states.last?.saving, false)
        XCTAssertEqual(states.last?.dirty, false)
        XCTAssertNotNil(states.last?.savedAt)
        XCTAssertEqual(toolbarStates, states, "Save feedback must remain synchronized across the shared observer's consumers")
    }
    @MainActor func testTimelinePresentationSeparatesPlaybackFromEditingAndActionRequests() async throws {
        let (controller, executor) = try show(fixture())
        let observer = ShowTimelinePresentationObserver(show: controller)
        var changes = 0
        let subscription = observer.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        func flush() async { await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } } }
        for step in 1...60 {
            executor.transport.position = 37.5 + Double(step) / 30
            controller.tick(); await flush()
        }
        XCTAssertEqual(changes, 0, "Playback samples must not reconstruct the static grid")
        executor.transport.editPosition = 35
        controller.tick(); await flush()
        XCTAssertEqual(changes, 1, "Moving the edit cursor still updates input coordinates")
        controller.selectTimelineRegion(try XCTUnwrap(controller.current?.parts.first?.id))
        await flush()
        XCTAssertEqual(changes, 2, "Region selection updates its white outline")
        let track = try XCTUnwrap(controller.current?.tracks.last?.id)
        controller.setMixerTrackSelection([track], anchor: track)
        await flush()
        XCTAssertEqual(changes, 3, "Mixer selection is reflected in the grid")
        controller.performAction(.splitItems); await flush()
        XCTAssertEqual(changes, 4, "Split works even when the project geometry has not changed")
        controller.performAction(.addTrack); await flush()
        XCTAssertEqual(changes, 5, "Add-track opens without requiring a playback tick")
        executor.transport.editPosition = nil
        controller.tick(); await flush()
        let before = changes
        for _ in 0..<30 {
            executor.transport.position += 0.03
            controller.tick(); await flush()
        }
        XCTAssertEqual(changes, before, "A missing edit cursor must not subscribe geometry to the playhead")
        executor.transport.subPlay.playing = true
        controller.tick(); await flush()
        XCTAssertEqual(changes, before + 1, "SubPlay still enables its cursor")
        executor.transport.subPlay.playing = false
        executor.transport.playing = false
        controller.tick(); await flush()
        XCTAssertEqual(changes, before + 2, "Stop restores stationary cursor coordinates")
        XCTAssertEqual(observer.state.editPosition, executor.transport.position)
    }
    @MainActor func testMixerPresentationIgnoresPlaybackTicksAndPublishesRealEdits() throws {
        let (controller, executor) = try show(fixture())
        var changes = 0
        let subscription = controller.projectPresentation.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        executor.transport.position += 1
        for _ in 0..<30 { controller.tick() }
        XCTAssertEqual(changes, 0, "Playback position must not rebuild mixer controls")
        let track = try XCTUnwrap(controller.current?.tracks.last?.id)
        controller.setMixerTrackSelection([track], anchor: track)
        XCTAssertEqual(changes, 1)
        controller.setMixerTrackSelection([track], anchor: track)
        XCTAssertEqual(changes, 1, "Unchanged selection must not invalidate mixer")
        controller.sendMixerControl(.volume, target: track, value: 0.5)
        XCTAssertGreaterThan(changes, 1)
        let afterVolume = changes
        controller.sendMixerControl(.mute, target: track)
        XCTAssertGreaterThan(changes, afterVolume)
        let afterMute = changes
        controller.sendMixerControl(.solo, target: track)
        XCTAssertGreaterThan(changes, afterMute)
        let afterSolo = changes
        controller.tick()
        XCTAssertEqual(changes, afterSolo)
    }
    @MainActor func testSelectedMixerControlsShareStatesAndPreserveUnselectedTracks() throws {
        var project = fixture()
        var a = Track(id: UUID(), name: "A", role: .keys)
        var b = Track(id: UUID(), name: "B", role: .keys)
        let c = Track(id: UUID(), name: "C", role: .keys)
        a.volume = 1; b.volume = 0.5; b.mute = true; b.solo = true; b.phaseInverted = true
        project.songs[0].tracks = [a,b,c]
        let (controller, executor) = try show(project)
        controller.setMixerTrackSelection([a.id,b.id], anchor: a.id)
        var revisions = Set<UInt64>()
        controller.audioUpdate = { _, revision in revisions.insert(revision) }
        for command: ShowCommand in [.mute,.solo,.phase] {
            controller.sendMixerControl(command, target: a.id)
        }
        let tracks = try XCTUnwrap(controller.current).tracks
        XCTAssertTrue(tracks[0].mute && tracks[1].mute && !tracks[2].mute)
        XCTAssertTrue(tracks[0].solo && tracks[1].solo && !tracks[2].solo)
        XCTAssertEqual(tracks[0].phaseInverted, true); XCTAssertEqual(tracks[1].phaseInverted, true)
        controller.sendMixerControl(.mute, target: c.id)
        XCTAssertTrue(controller.current!.tracks.allSatisfy(\.mute))
        XCTAssertEqual(controller.mixerTrackSelection, [a.id,b.id])
        XCTAssertEqual(revisions.count, 1, "Scalar changes retain the same audio project revision")
        XCTAssertEqual(executor.fullEdits, 0); XCTAssertEqual(executor.snapshotReads, 0)
    }
    @MainActor func testSelectedVolumePreviewMaintainsRatiosAndSilenceEqualizesWithinGesture() throws {
        var project = fixture()
        var a = Track(id: UUID(), name: "A", role: .keys)
        var b = Track(id: UUID(), name: "B", role: .keys)
        a.volume = 1; b.volume = 0.25
        project.songs[0].tracks = [a,b]
        let (controller, executor) = try show(project)
        controller.setMixerTrackSelection([a.id,b.id], anchor: a.id)
        var live: [UUID:Double] = [:]
        controller.audioVolume = { id, gain in if let id { live[id] = gain } }
        controller.sendMixerControl(.volume, target: a.id, value: 0.5, preview: true)
        XCTAssertEqual(live[a.id], 0.5); XCTAssertEqual(live[b.id], 0.125)
        XCTAssertEqual(controller.current!.tracks[0].volume, 1, "Dragging must not publish full project changes")
        controller.sendMixerControl(.volume, target: a.id, value: 0, preview: true)
        XCTAssertEqual(live[b.id], 0)
        controller.sendMixerControl(.volume, target: a.id, value: 0.2, preview: true)
        XCTAssertEqual(live[a.id], 0.2); XCTAssertEqual(live[b.id], 0.2)
        controller.sendMixerControl(.volume, target: a.id, value: 0.2)
        XCTAssertEqual(controller.current!.tracks.map(\.volume), [0.2,0.2])
        XCTAssertEqual(executor.fullEdits, 0); XCTAssertEqual(executor.snapshotReads, 0)
        controller.undo()
        XCTAssertEqual(controller.current!.tracks.map(\.volume), [1,0.25], "One undo restores the entire multi-track gesture")
    }
    @MainActor func testSelectedPanMovesTogetherAndLinkedPairStaysOpposed() throws {
        var project = fixture()
        var a = Track(id: UUID(), name: "A", role: .keys)
        var b = Track(id: UUID(), name: "B", role: .keys)
        var c = Track(id: UUID(), name: "C", role: .keys)
        a.pan = -0.2; b.pan = 0.1; c.pan = 0.3
        project.songs[0].tracks = [a,b,c]
        let (controller, _) = try show(project)
        controller.setMixerTrackSelection([a.id,b.id], anchor: a.id)
        controller.sendMixerControl(.pan, target: a.id, value: 0.1, preview: true)
        XCTAssertEqual(controller.mixerPreviewValues[b.id]!, 0.4, accuracy: 0.000001)
        controller.sendMixerControl(.pan, target: a.id, value: 0.1)
        XCTAssertEqual(controller.current!.tracks[2].pan, 0.3)
        controller.linkTracks([a.id,b.id], defaultInput: 1, color: 0xffffff)
        controller.setMixerTrackSelection([a.id,b.id,c.id], anchor: b.id)
        var live: [UUID:Double] = [:]
        controller.audioPan = { live[$0] = $1 }
        controller.sendMixerControl(.pan, target: b.id, value: 0.4, preview: true)
        XCTAssertEqual(live[a.id]!, -0.4, accuracy: 0.000001); XCTAssertEqual(live[b.id]!, 0.4, accuracy: 0.000001)
        controller.sendMixerControl(.pan, target: b.id, value: 0.4)
        XCTAssertEqual(controller.current!.tracks[0].pan, -0.4, accuracy: 0.000001)
        XCTAssertEqual(controller.current!.tracks[1].pan, 0.4, accuracy: 0.000001)
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
    @MainActor func testMasterSoloAndColorAreIncrementalAndPreserveTransport() throws {
        let project = fixture(), (show, executor) = try show(project)
        let transport = show.snapshot.transport
        var solos: [Bool] = [], audioRevisions: [UInt64] = []
        show.audioMasterSolo = { solos.append($0) }
        show.audioUpdate = { _, revision in audioRevisions.append(revision) }
        show.send(.solo)
        XCTAssertEqual(show.snapshot.project.masterSolo, true)
        show.performAction(.soloMaster)
        XCTAssertEqual(show.snapshot.project.masterSolo, false)
        show.editMasterColor(0x12ab34)
        show.editMasterColor(0x12ab34)
        show.editMasterColor(0x1000000)
        XCTAssertEqual(solos, [true, false])
        XCTAssertEqual(show.snapshot.project.masterColor, 0x12ab34)
        XCTAssertEqual(executor.settingsCommands, ["masterColor"])
        XCTAssertEqual(executor.snapshotReads, 0); XCTAssertEqual(executor.playbackReads, 0); XCTAssertEqual(executor.fullEdits, 0)
        XCTAssertTrue(audioRevisions.allSatisfy { $0 == 0 })
        XCTAssertEqual(show.snapshot.transport, transport)
        XCTAssertEqual(show.snapshot.project, executor.project)
        executor.failMixerCommand = .solo
        executor.failSettingsCommand = "masterColor"
        show.send(.solo); show.editMasterColor(0xabcdef)
        XCTAssertEqual(solos, [true, false]); XCTAssertEqual(show.snapshot.project.masterColor, 0x12ab34)
        XCTAssertEqual(show.snapshot.transport, transport)
        let data = try JSONEncoder().encode(show.snapshot.project)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: data), show.snapshot.project)
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
    @MainActor func testBatchRegionColorsPreserveNamesAndTimingWithoutReload() throws {
        var project = fixture()
        project.songs[0].parts.append(Part(id: UUID(), name: "Second (original)", startTime: 20, endTime: 30))
        project.songs[0].parts.append(Part(id: UUID(), name: "Untouched", startTime: 30, endTime: 40))
        let original = project.songs[0].parts
        let (show, executor) = try show(project)
        show.editRegionColors(Set(original.prefix(2).map(\.id)), color: 0x123456)
        XCTAssertEqual(show.current?.parts.map(\.name), original.map(\.name))
        XCTAssertEqual(show.current?.parts.map(\.startTime), original.map(\.startTime))
        XCTAssertEqual(show.current?.parts.map(\.endTime), original.map(\.endTime))
        XCTAssertEqual(show.current?.parts[0].color, 0x123456)
        XCTAssertEqual(show.current?.parts[1].color, 0x123456)
        XCTAssertEqual(show.current?.parts[2], original[2])
        XCTAssertEqual(executor.fullEdits, 0)
        XCTAssertEqual(executor.snapshotReads, 0)
    }
    @MainActor func testBatchTrackColorKeepsEveryNameAndCreatesOneUndoWithoutReload() throws {
        var project = fixture()
        project.songs[0].tracks.append(Track(id: UUID(), name: "Untouched", role: .bass))
        let (show, executor) = try show(project)
        let tracks = Set(project.songs[0].tracks.prefix(2).map(\.id))
        let transport = show.snapshot.transport
        var updates = 0, edits = 0
        show.audioUpdate = { _, revision in XCTAssertEqual(revision, 0); updates += 1 }
        show.onProjectEdited = { edits += 1 }
        show.editTrackColors(tracks, color: 0x5ebb73, project: project.id)
        var expected = project
        for row in 0..<2 { expected.songs[0].tracks[row].color = 0x5ebb73 }
        XCTAssertEqual(show.snapshot.project, expected)
        XCTAssertEqual(executor.project, expected)
        XCTAssertEqual(show.snapshot.transport, transport)
        XCTAssertEqual(executor.settingsCommands, ["details", "details"])
        XCTAssertEqual(executor.fullEdits, 0); XCTAssertEqual(executor.snapshotReads, 0)
        XCTAssertEqual(show.projectRevision, 1); XCTAssertEqual(updates, 1); XCTAssertEqual(edits, 1)
        show.editTrackColors(tracks, color: 0x5ebb73, project: project.id)
        show.editTrackColors(tracks, color: 0xff0000, project: UUID())
        show.editTrackColors([UUID()], color: 0xff0000, project: project.id)
        show.editTrackColors(tracks, color: 0xffffff01, project: project.id)
        XCTAssertEqual(executor.settingsCommands.count, 2)
        XCTAssertEqual(show.projectRevision, 1)
        show.audioUpdate = { _, _ in }
        show.undo()
        XCTAssertEqual(show.snapshot.project, project)
        XCTAssertFalse(show.canUndo, "The complete selection must be one undo operation")
        show.redo()
        XCTAssertEqual(show.snapshot.project, expected)
        XCTAssertFalse(show.canRedo)
    }
    @MainActor func testPartialColorFailureKeepsBackendAndSnapshotInSyncAndIsUndoable() throws {
        let project = fixture(), (show, executor) = try show(project)
        executor.failSettingsCommandAt = 2
        show.editTrackColors(Set(project.songs[0].tracks.map(\.id)), color: 0x5ebb73, project: project.id)
        var expected = project
        expected.songs[0].tracks[0].color = 0x5ebb73
        XCTAssertEqual(show.snapshot.project, expected)
        XCTAssertEqual(executor.project, expected)
        XCTAssertFalse(show.message.isEmpty)
        XCTAssertEqual(show.projectRevision, 1)
        XCTAssertEqual(executor.fullEdits, 0); XCTAssertEqual(executor.snapshotReads, 0)
        show.undo()
        XCTAssertEqual(show.snapshot.project, project)
        XCTAssertFalse(show.canUndo)
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
    @MainActor func testPhaseChangesAudioWithoutReloadAndSupportsUndo() throws {
        let project = fixture(), (show, executor) = try show(project)
        let track = project.songs[0].tracks[1].id
        let transport = show.snapshot.transport
        var targets: [UUID?] = [], values: [Bool] = [], revisions: [UInt64] = []
        show.audioUpdate = { _, revision in revisions.append(revision) }
        show.audioPhase = { targets.append($0); values.append($1) }
        show.send(.phase, target: track)
        show.send(.phase)
        XCTAssertEqual(targets, [track]); XCTAssertEqual(values, [true])
        XCTAssertEqual(show.current?.tracks[1].phaseInverted, true)
        XCTAssertNotEqual(show.snapshot.project.masterPhaseInverted, true)
        XCTAssertEqual(show.snapshot.transport, transport)
        XCTAssertEqual(executor.fullEdits, 0); XCTAssertEqual(executor.snapshotReads, 0)
        XCTAssertEqual(show.projectRevision, 1); XCTAssertEqual(revisions, [0])
        show.undo(); show.undo()
        XCTAssertEqual(show.snapshot.project, project)
        show.redo(); show.redo()
        XCTAssertEqual(show.current?.tracks[1].phaseInverted, true)
        XCTAssertNotEqual(show.snapshot.project.masterPhaseInverted, true)
    }
    @MainActor func testChannelConversionPreservesSourceAndAllEditsAndRestoresStereoWithUndo() throws {
        let project = fixture(), (show, executor) = try show(project)
        let clips = project.songs[0].tracks[1].clips
        let ids = Set(clips.map(\.id))
        XCTAssertTrue(show.convertItems(ids, mode: 3))
        XCTAssertEqual(executor.fullEdits, 0)
        XCTAssertEqual(executor.snapshotReads, 0)
        var converted = show.current!.tracks[1].clips
        XCTAssertTrue(converted.allSatisfy { $0.channelMode == 3 })
        for index in converted.indices { converted[index].channelMode = nil }
        XCTAssertEqual(converted, clips, "Channel conversion preserves source paths, gain, FX, mute and position")
        show.undo(); XCTAssertEqual(show.snapshot.project, project)
        show.redo(); XCTAssertTrue(show.current!.tracks[1].clips.allSatisfy { $0.channelMode == 3 })
        XCTAssertTrue(show.convertItems(ids, mode: 0))
        XCTAssertEqual(show.current!.tracks[1].clips, clips)
    }
    @MainActor func testNormalizationCommitsScalarBatchOnceAndUndoRestoresWholeBatch() throws {
        let project = fixture(), (show,executor) = try show(project)
        let clips = project.songs[0].tracks[1].clips
        let capped = pow(10,24.0 / 20)
        var gains: [IncrementalSettingsExecutor.GainCommand] = [], revisions: [UInt64] = []
        show.audioItemNormalization = { gains.append(.init(item: $0,value: $1)) }
        show.audioUpdate = { _,revision in revisions.append(revision) }
        XCTAssertTrue(show.normalizeItems([clips[0].id: 100,clips[1].id: 0.25],project: project.id))
        let expected: [IncrementalSettingsExecutor.GainCommand] = [.init(item: clips[0].id,value: capped),.init(item: clips[1].id,value: 0.25)]
        XCTAssertEqual(executor.gainCommands,expected); XCTAssertEqual(gains,expected)
        XCTAssertEqual(executor.snapshotReads,0); XCTAssertEqual(executor.playbackReads,0); XCTAssertEqual(executor.fullEdits,0)
        XCTAssertEqual(revisions,[0]); XCTAssertEqual(show.projectRevision,1); XCTAssertTrue(show.canUndo)
        XCTAssertEqual(show.current?.tracks[1].clips[0].waveform,clips[0].waveform)
        XCTAssertEqual(show.current?.tracks[1].clips[0].waveformChannels,clips[0].waveformChannels)
        XCTAssertEqual(show.current?.tracks[1].clips.map(\.gain), clips.map(\.gain), "normalization preserves volume knobs")
        show.undo()
        XCTAssertEqual(show.snapshot.project,project); XCTAssertFalse(show.canUndo); XCTAssertTrue(show.canRedo)
        show.redo()
        XCTAssertEqual(show.current?.tracks[1].clips.map { $0.normalizationGain ?? 1 },[capped,0.25])
        XCTAssertEqual(executor.fullEdits,2)
    }
    @MainActor func testFailedNormalizationRollsBackAppliedScalarsWithoutPublishingOrUndo() throws {
        let project = fixture(), (show,executor) = try show(project)
        let clips = project.songs[0].tracks[1].clips
        executor.failGainCommand = 2
        var audioWrites = 0, audioUpdates = 0
        show.audioItemNormalization = { _,_ in audioWrites += 1 }; show.audioUpdate = { _,_ in audioUpdates += 1 }
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
        XCTAssertTrue(show.normalizeItems([clips[0].id: 1,clips[1].id: 1],project: project.id))
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
        XCTAssertEqual(show.mixerTrackSelection, [track], "actions publish selection immediately for automatic REC, even without a mounted grid")
        XCTAssertEqual(firstRequest?.track, track)
        show.performAction(.selectTrack, trackNumber: 2)
        XCTAssertNotEqual(show.trackSelectionRequest?.id, firstRequest?.id)
        show.performAction(.muteTrack)
        show.performAction(.soloTrack)
        show.performAction(.volumeTrack, midiValue: 0)
        show.performAction(.panTrack, midiValue: 64)
        show.performAction(.muteMaster)
        show.performAction(.volumeMaster, midiValue: 64)
        XCTAssertTrue(show.snapshot.project.masterMute == true)
        XCTAssertEqual(show.snapshot.project.masterVolume ?? 1, MIDIFaderValue.gain(64))
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
