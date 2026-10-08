import XCTest
import Combine
@testable import JarasApplication

@MainActor private final class SectionExecutor: CommandExecutor {
    var project = Project.demo()
    var transport = TransportState(playing: true, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0))
    var commands: [ShowCommand] = []
    var scalarWrites: [(ShowCommand, UUID?, Double)] = []
    func load(_ project: Project) throws { self.project = project; transport.songId = project.songs[0].id }
    func snapshot() throws -> ShowSnapshot { ShowSnapshot(project: project, transport: transport) }
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: transport) }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws {
        commands.append(command)
        scalarWrites.append((command, target, value))
        if command == .escape, transport.queuedSectionMarkerId != nil {
            transport.queuedSectionMarkerId = nil; transport.sectionQueueStartedAt = nil
            return
        }
        if command == .toggleMultiLoopBypass {
            transport.multiLoopsBypassed = transport.multiLoopsBypassed != true
            if transport.multiLoopsBypassed == true { transport.multiLoop = nil; transport.loop.enabled = false }
            return
        }
        if command == .stop || command == .stopAll {
            transport.playing = false; transport.paused = false; transport.subPlay.playing = false
            transport.multiLoop = nil; transport.loop.enabled = false
            return
        }
        if command == .pause { transport.playing = false; transport.paused = true; return }
        if command == .play { transport.playing = true; transport.paused = false; return }
        if target == nil {
            if command == .volume { project.masterVolume = value }
            if command == .mute { project.masterMute = project.masterMute != true }
            if command == .solo { project.masterSolo = project.masterSolo != true }
            return
        }
        for s in project.songs.indices {
            guard let t = project.songs[s].tracks.firstIndex(where: { $0.id == target }) else { continue }
            switch command {
            case .volume: project.songs[s].tracks[t].volume = value
            case .mute: project.songs[s].tracks[t].mute.toggle()
            case .solo: project.songs[s].tracks[t].solo.toggle()
            default: break
            }
        }
    }
    func applyProjectEdit(_ project: Project) throws { self.project = project }
    func addTrack(id: UUID, name: String, role: TrackRole) throws {}
    func advance(_ elapsed: Double) {}
    func finishCurrentSong(_ enabled: Bool) {}
}
final class SmoothSeekTests: XCTestCase {
    func testPlayingSectionProgressUsesItsOwnBoundsAndResetsAfterSeek() {
        XCTAssertEqual(SectionPlaybackProgress.fraction(position: 15, start: 10, end: 30), 0.25)
        XCTAssertEqual(SectionPlaybackProgress.fraction(position: 29.9, start: 10, end: 30), 0.995, accuracy: 0.00001)
        XCTAssertEqual(SectionPlaybackProgress.fraction(position: 30, start: 30, end: 50), 0)
        XCTAssertEqual(SectionPlaybackProgress.fraction(position: 10, start: 10, end: 30), 0)
        XCTAssertEqual(SectionPlaybackProgress.fraction(position: 5, start: 10, end: 30), 0)
        XCTAssertEqual(SectionPlaybackProgress.fraction(position: 40, start: 10, end: 30), 1)
        XCTAssertEqual(SectionPlaybackProgress.fraction(position: 10, start: 10, end: 10), 0)
        XCTAssertEqual(SectionPlaybackProgress.fraction(position: .nan, start: 10, end: 30), 0)
    }

    func testStartDestinationFollowsRegionWithoutCreatingMarker() {
        var song = Project.demo().songs[0]
        let region = Part(id: UUID(), name: "Song", startTime: 5, endTime: 20)
        let cue = TimelineMarker(id: UUID(), name: "Cue", position: 8, color: 0)
        let section = TimelineMarker(id: UUID(), name: "$VERSE", position: 10, color: 0, section: true)
        song.parts = [region]; song.markers = [cue, section]
        XCTAssertEqual(song.sectionDestinationPosition(region.id), 5)
        XCTAssertEqual(song.sectionDestinationPosition(section.id), 10)
        XCTAssertNil(song.sectionDestinationPosition(cue.id))
        song.parts[0].startTime = 7
        XCTAssertEqual(song.sectionDestinationPosition(region.id), 7)
        song.parts = []
        XCTAssertNil(song.sectionDestinationPosition(region.id))
        XCTAssertEqual(song.markers?.count, 2)
    }
    @MainActor func testCancellingSectionKeepsAutoAndQueuedSong() throws {
        var project = Project.demo()
        project.regionSetlist = RegionSetlist()
        project.regionSetlist?.autoAdvance = true
        let backend = SectionExecutor()
        let show = try ShowController(executor: backend, persistence: MemoryProjectStore(), initialProject: project)
        let queuedSong = UUID()
        backend.transport.queuedSectionMarkerId = UUID()
        backend.transport.queuedRegionId = queuedSong
        backend.transport.loop.enabled = true
        show.tick()
        let revision = show.projectRevision
        show.send(.escape)
        XCTAssertNil(show.snapshot.transport.queuedSectionMarkerId)
        XCTAssertTrue(show.snapshot.transport.loop.enabled)
        XCTAssertEqual(show.snapshot.transport.queuedRegionId, queuedSong)
        XCTAssertEqual(show.snapshot.project.regionSetlist?.autoAdvance, true)
        XCTAssertEqual(show.projectRevision, revision, "cancelled section is a transport change only")
    }
    func testSectionsSurviveDocumentAndOrdinaryCuesAreNotLoopChoices() throws {
        var p = Project.demo()
        p.songs[0].parts = [Part(id: UUID(), name: "Song", startTime: 5, endTime: 20)]
        p.songs[0].markers = [TimelineMarker(id: UUID(), name: "Cue", position: 8, color: 0), TimelineMarker(id: UUID(), name: "Chorus", position: 10, color: 0x51ef93, section: true)]
        let copy = try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(p))
        XCTAssertEqual(copy.songs[0].markers, p.songs[0].markers)
        XCTAssertEqual(copy.songs[0].sectionMarkers(in: copy.songs[0].parts[0]).map(\.name), ["Chorus"])
        XCTAssertTrue(copy.songs[0].multiLoopMarkers(in: copy.songs[0].parts[0]).isEmpty)
        XCTAssertNil(copy.songs[0].sectionRegion(at: 4.99))
        XCTAssertNotNil(copy.songs[0].sectionRegion(at: 5))
        XCTAssertNil(copy.songs[0].sectionRegion(at: 20))
    }
    func testDrawerSectionOwnershipAndPanelCapacity() {
        var song = Project.demo().songs[0]
        let parent = Part(id: UUID(), name: "Special", startTime: 0, endTime: 30)
        let child = Part(id: UUID(), name: "Child", startTime: 10, endTime: 20, parentRegionID: parent.id)
        song.parts = [parent, child]
        XCTAssertEqual(song.sectionRegion(at: 12)?.id, child.id)
        XCTAssertEqual(SmoothSeekPanelLayout.visibleRows(for: 12), 2)
        XCTAssertEqual(SmoothSeekPanelLayout.visibleRows(for: 13), 3)
        XCTAssertEqual(SmoothSeekPanelLayout.visibleRows(for: 18), 3)
        XCTAssertEqual(SmoothSeekPanelLayout.visibleRows(for: 19), 4)
        XCTAssertEqual(SmoothSeekPanelLayout.visibleRows(for: 25), 4)
        XCTAssertEqual(SmoothSeekPanelLayout.visibleRows(for: 33), 4)
        for available in [0.0, 80, 240, 330, 1024] {
            for requested in [-100.0, 0, 160, 3000, .infinity, .nan] {
                let width = SmoothSeekPanelLayout.sidebarWidth(available: available, requested: requested, minimumPrimary: 140)
                XCTAssertTrue(width.isFinite)
                XCTAssertGreaterThanOrEqual(width, 0)
                XCTAssertLessThanOrEqual(width, available)
                XCTAssertGreaterThanOrEqual(available - width, min(140, available * 0.6))
            }
        }
    }
    @MainActor func testLoopGatesUseRealMixerCommandsWhileAutoFaderPreservesManualVolume() throws {
        let backend = SectionExecutor()
        let show = try ShowController(executor: backend, persistence: MemoryProjectStore(), initialProject: Project.demo())
        let track = show.current!.tracks[0]
        var rule = MultiLoopTrack(id: track.id, gain: 0.2)
        rule.autoFader = true; rule.solo = true; rule.mute = true
        backend.transport.multiLoop = MultiLoopPlayback(id: UUID(), start: 10, end: 20, amount: 0.5, gates: false, released: false, tracks: [rule])
        let revision = show.projectRevision
        var publications = 0, volumeWrites = 0
        var revisions: [UInt64] = []
        let observation = show.projectPresentation.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        show.audioVolume = { _, _ in volumeWrites += 1 }
        show.audioUpdate = { _, revision in revisions.append(revision) }
        show.tick()
        XCTAssertEqual(show.mixerPlaybackRevision, 0)
        XCTAssertEqual(show.projectRevision, revision, "fader animation does not invalidate waveform geometry")
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(show.current!.tracks[0].volume, track.volume)
        XCTAssertEqual(backend.project.songs[0].tracks[0].volume, track.volume)
        XCTAssertFalse(show.current!.tracks[0].solo)
        backend.transport.multiLoop!.amount = 1; backend.transport.multiLoop!.gates = true
        show.tick()
        XCTAssertEqual(show.current!.tracks[0].volume, track.volume)
        XCTAssertTrue(show.current!.tracks[0].solo)
        XCTAssertTrue(show.current!.tracks[0].mute)
        XCTAssertEqual(backend.commands, [.mute, .solo])
        XCTAssertEqual(publications, 1, "M/S remain visible in one combined project publication")
        XCTAssertEqual(show.projectRevision, revision + 2)
        XCTAssertEqual(show.mixerPlaybackRevision, 2)
        for step in 1...30 {
            backend.transport.multiLoop!.released = true
            backend.transport.multiLoop!.amount = 1 - Double(step) / 30
            show.tick()
        }
        XCTAssertEqual(backend.commands, [.mute, .solo], "release gain does not resend the discrete gates")
        XCTAssertEqual(publications, 1)
        backend.transport.multiLoop = nil
        show.tick()
        XCTAssertEqual(show.current!.tracks[0].volume, track.volume, accuracy: 0.000001)
        XCTAssertEqual(show.current!.tracks[0].solo, track.solo)
        XCTAssertEqual(show.current!.tracks[0].mute, track.mute)
        XCTAssertEqual(backend.project.songs[0].tracks[0], show.current!.tracks[0])
        XCTAssertEqual(publications, 2)
        XCTAssertEqual(volumeWrites, 0)
        XCTAssertFalse(backend.commands.contains(.volume))
        XCTAssertEqual(Set(revisions), [0], "gates and fades do not rebuild the audio project")
        XCTAssertFalse(show.hasUnsavedChanges)
        XCTAssertFalse(show.canUndo)
    }
    @MainActor func testManyAutoFadersNeverPublishProjectOrChangeManualGainsAndHistory() throws {
        let backend = SectionExecutor()
        var project = Project.demo()
        let original = project.songs[0].tracks[0]
        project.songs[0].tracks = (0..<24).map { index in
            var track = original; track.id = UUID(); track.name = "Fade \(index)"
            track.stereoLink = nil; track.parentTrackID = nil; track.volume = 1; track.mute = false; track.solo = false
            return track
        }
        let show = try ShowController(executor: backend, persistence: MemoryProjectStore(), initialProject: project)
        var rules = project.songs[0].tracks.map { track in
            var rule = MultiLoopTrack(id: track.id, gain: 0); rule.autoFader = true; return rule
        }
        var master = MultiLoopTrack(id: MultiLoopTrack.masterID, gain: 0.1); master.autoFader = true
        rules.append(master)
        var publications = 0, snapshotPublications = 0
        let observation = show.projectPresentation.objectWillChange.sink { publications += 1 }
        let snapshots = show.$snapshot.dropFirst().sink { _ in snapshotPublications += 1 }
        defer { observation.cancel(); snapshots.cancel() }
        var volumeWrites = 0, audioFrames: [ShowSnapshot] = [], revisions: [UInt64] = []
        show.audioVolume = { _, _ in volumeWrites += 1 }
        show.audioUpdate = { snapshot, revision in audioFrames.append(snapshot); revisions.append(revision) }
        backend.transport.multiLoop = MultiLoopPlayback(id: UUID(), start: 10, end: 20,
            amount: 0, gates: false, released: false, tracks: rules)
        let revision = show.projectRevision
        for step in 0..<120 {
            let amount = step < 60 ? Double(step) / 59 : Double(119 - step) / 59
            backend.transport.multiLoop!.amount = amount
            backend.transport.multiLoop!.released = step >= 60
            show.tick()
            XCTAssertEqual(audioFrames.last?.transport.multiLoop, backend.transport.multiLoop)
            XCTAssertEqual(audioFrames.last?.project, project)
        }
        XCTAssertEqual(publications, 0, "continuous internal gains never publish mixer project frames")
        XCTAssertEqual(snapshotPublications, 120, "each tick publishes only its transport sample")
        XCTAssertEqual(audioFrames.count, 120)
        XCTAssertEqual(volumeWrites, 0)
        XCTAssertTrue(backend.commands.isEmpty, "Auto Fader does not send engine volume commands")
        XCTAssertEqual(show.snapshot.project, project)
        XCTAssertEqual(backend.project, project)
        XCTAssertEqual(show.projectRevision, revision)
        XCTAssertEqual(show.mixerPlaybackRevision, 0)
        XCTAssertEqual(Set(revisions), [0])
        XCTAssertFalse(show.hasUnsavedChanges)
        XCTAssertFalse(show.canUndo)
        XCTAssertFalse(show.canRedo)
        backend.transport.multiLoop = nil; show.tick()
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(snapshotPublications, 121)
        XCTAssertNil(audioFrames.last?.transport.multiLoop)
        XCTAssertEqual(show.snapshot.project, project)
        XCTAssertTrue(backend.commands.isEmpty)
    }
    @MainActor func testManualAndLinkedVolumeEditsRemainIndependentOfRunningAutoFader() throws {
        let backend = SectionExecutor()
        var project = Project.empty(name: "Manual during fade")
        let left = Track(id: UUID(), name: "Left", role: .keys)
        let right = Track(id: UUID(), name: "Right", role: .keys)
        project.songs[0].tracks = [left, right]
        project.songs[0].linkTracks([left.id, right.id], firstInput: 1, color: 0xffffff)
        project.masterVolume = 0.8
        let show = try ShowController(executor: backend, persistence: MemoryProjectStore(), initialProject: project)
        var rule = MultiLoopTrack(id: left.id, gain: 0.1); rule.autoFader = true
        var master = MultiLoopTrack(id: MultiLoopTrack.masterID, gain: 0); master.autoFader = true
        backend.transport.multiLoop = MultiLoopPlayback(id: UUID(), start: 10, end: 20,
            amount: 0.75, gates: false, released: false, tracks: [rule, master])
        var gains: [UUID: Double] = [:], masterGains: [Double] = []
        show.audioVolume = { id, gain in if let id { gains[id] = gain } else { masterGains.append(gain) } }
        show.tick()
        show.sendMixerControl(.volume, target: left.id, value: 0.4, preview: true)
        XCTAssertEqual(gains, [left.id: 0.4, right.id: 0.4], "renderer receives manual gain for both linked channels")
        XCTAssertEqual(show.current!.tracks.map(\.volume), [1, 1], "preview retains the committed project")
        XCTAssertEqual(backend.project.songs[0].tracks.map(\.volume), [0.4, 0.4])
        let writesDuringPreview = backend.scalarWrites.count
        show.tick()
        XCTAssertEqual(backend.scalarWrites.count, writesDuringPreview, "the following fade tick cannot overwrite the manual preview")
        XCTAssertEqual(show.current!.tracks.map(\.volume), [1, 1])
        XCTAssertEqual(backend.project.songs[0].tracks.map(\.volume), [0.4, 0.4])
        show.sendMixerControl(.volume, target: left.id, value: 0.4)
        XCTAssertEqual(show.current!.tracks.map(\.volume), [0.4, 0.4])
        XCTAssertTrue(show.canUndo)
        let committedRevision = show.projectRevision
        let committedWrites = backend.scalarWrites.count
        for amount in [0.9, 1, 0.5, 0] {
            backend.transport.multiLoop!.amount = amount; show.tick()
        }
        XCTAssertEqual(show.current!.tracks.map(\.volume), [0.4, 0.4])
        XCTAssertEqual(show.projectRevision, committedRevision)
        XCTAssertEqual(backend.scalarWrites.count, committedWrites)
        backend.transport.multiLoop = nil; show.tick()
        show.undo()
        XCTAssertEqual(show.current!.tracks.map(\.volume), [1, 1])
        XCTAssertFalse(show.canUndo, "only the user's commit creates history")
        show.redo()
        XCTAssertEqual(show.current!.tracks.map(\.volume), [0.4, 0.4])

        backend.transport.multiLoop = MultiLoopPlayback(id: UUID(), start: 10, end: 20,
            amount: 1, gates: false, released: false, tracks: [master])
        show.tick()
        show.sendMixerControl(.volume, target: nil, value: 0.3, preview: true)
        XCTAssertEqual(masterGains.last, 0.3)
        XCTAssertEqual(show.snapshot.project.masterVolume, 0.8)
        XCTAssertEqual(backend.project.masterVolume, 0.3)
        show.tick()
        XCTAssertEqual(masterGains, [0.3])
        show.sendMixerControl(.volume, target: nil, value: 0.3)
        backend.transport.multiLoop = nil; show.tick()
        XCTAssertEqual(show.snapshot.project.masterVolume, 0.3)
        XCTAssertEqual(backend.project.masterVolume, 0.3)
    }
    @MainActor func testLoopRuleRemovalBypassPauseAndStopRestoreOnlyDiscreteGates() throws {
        let backend = SectionExecutor()
        let show = try ShowController(executor: backend, persistence: MemoryProjectStore(), initialProject: Project.demo())
        defer { show.send(.stopAll) }
        let original = show.snapshot.project
        let track = original.songs[0].tracks[0]
        var rule = MultiLoopTrack(id: track.id, gain: 0); rule.autoFader = true; rule.mute = true
        var master = MultiLoopTrack(id: MultiLoopTrack.masterID, gain: 0); master.autoFader = true; master.solo = true
        let loop = MultiLoopPlayback(id: UUID(), start: 10, end: 20,
            amount: 1, gates: true, released: false, tracks: [rule, master])
        var audioFrames: [ShowSnapshot] = [], volumeWrites = 0
        show.audioUpdate = { snapshot, _ in audioFrames.append(snapshot) }
        show.audioVolume = { _, _ in volumeWrites += 1 }
        backend.transport.multiLoop = loop; show.tick()
        XCTAssertTrue(show.current!.tracks[0].mute)
        XCTAssertEqual(show.snapshot.project.masterSolo, true)
        show.send(.pause)
        XCTAssertEqual(audioFrames.last?.transport.multiLoop, loop, "pause retains the same effective fade for resume")
        XCTAssertTrue(show.snapshot.transport.paused == true)
        show.send(.play)
        backend.transport.multiLoop!.tracks = []
        show.tick()
        XCTAssertEqual(show.current!.tracks[0].mute, track.mute)
        XCTAssertEqual(show.snapshot.project.masterSolo ?? false, original.masterSolo ?? false)
        backend.transport.multiLoop = loop; show.tick()
        show.send(.toggleMultiLoopBypass)
        XCTAssertNil(audioFrames.last?.transport.multiLoop)
        XCTAssertEqual(show.current!.tracks[0].mute, track.mute)
        XCTAssertEqual(show.snapshot.project.masterSolo ?? false, original.masterSolo ?? false)
        backend.transport.multiLoopsBypassed = false
        backend.transport.multiLoop = loop; show.tick()
        show.send(.stopAll)
        XCTAssertNil(audioFrames.last?.transport.multiLoop)
        XCTAssertFalse(show.isPlaying)
        XCTAssertEqual(show.current!.tracks[0].mute, track.mute)
        XCTAssertEqual(show.snapshot.project.masterSolo ?? false, original.masterSolo ?? false)
        XCTAssertEqual(show.current!.tracks[0].volume, track.volume)
        XCTAssertEqual(backend.project.songs[0].tracks[0].volume, track.volume)
        XCTAssertEqual(volumeWrites, 0)
        XCTAssertFalse(backend.commands.contains(.volume))
        XCTAssertFalse(show.hasUnsavedChanges)
        XCTAssertFalse(show.canUndo)
    }
    @MainActor func testLoopAndSongTransitionsDeliverCurrentRuntimeRulesWithoutVolumeEdits() throws {
        let backend = SectionExecutor()
        var project = Project.empty(name: "Transitions")
        let first = Track(id: UUID(), name: "First", role: .keys)
        let second = Track(id: UUID(), name: "Second", role: .keys)
        project.songs[0].tracks = [first]
        var nextSong = project.songs[0]; nextSong.id = UUID(); nextSong.name = "Next"; nextSong.tracks = [second]
        project.songs.append(nextSong)
        let show = try ShowController(executor: backend, persistence: MemoryProjectStore(), initialProject: project)
        var rule = MultiLoopTrack(id: first.id, gain: 0.25); rule.autoFader = true
        var loop = MultiLoopPlayback(id: UUID(), start: 10, end: 20,
            amount: 0.5, gates: false, released: false, tracks: [rule])
        var audioFrames: [ShowSnapshot] = [], volumeWrites = 0
        show.audioUpdate = { snapshot, _ in audioFrames.append(snapshot) }
        show.audioVolume = { _, _ in volumeWrites += 1 }
        backend.transport.multiLoop = loop; show.tick()
        loop.id = UUID(); loop.amount = 0.9; loop.tracks[0].gain = 0.1
        backend.transport.multiLoop = loop; show.tick()
        XCTAssertEqual(audioFrames.last?.transport.multiLoop, loop)
        loop.tracks[0].id = second.id; loop.id = UUID()
        backend.transport.songId = nextSong.id; backend.transport.multiLoop = loop
        show.tick()
        XCTAssertEqual(audioFrames.last?.transport.songId, nextSong.id)
        XCTAssertEqual(audioFrames.last?.transport.multiLoop, loop)
        XCTAssertEqual(audioFrames.last?.project, project)
        backend.transport.multiLoop!.tracks[0].autoFader = false; show.tick()
        XCTAssertEqual(audioFrames.last?.transport.multiLoop?.tracks[0].autoFader, false)
        backend.transport.multiLoop = nil; show.tick()
        XCTAssertNil(audioFrames.last?.transport.multiLoop)
        XCTAssertEqual(show.snapshot.project, project)
        XCTAssertEqual(backend.project, project)
        XCTAssertEqual(volumeWrites, 0)
        XCTAssertTrue(backend.commands.isEmpty)
        XCTAssertEqual(show.mixerPlaybackRevision, 0)
        XCTAssertFalse(show.hasUnsavedChanges)
        XCTAssertFalse(show.canUndo)
    }
    @MainActor func testConflictingLinkedPresetsRetainLegacyVolumeCommandsOnlyForThatPair() throws {
        let backend = SectionExecutor()
        var project = Project.empty(name: "Conflicting linked presets")
        let left = Track(id: UUID(), name: "Left", role: .keys)
        let right = Track(id: UUID(), name: "Right", role: .keys)
        let ordinary = Track(id: UUID(), name: "Ordinary", role: .keys)
        project.songs[0].tracks = [left, right, ordinary]
        project.songs[0].linkTracks([left.id, right.id], firstInput: 1, color: 0xffffff)
        let show = try ShowController(executor: backend, persistence: MemoryProjectStore(), initialProject: project)
        var a = MultiLoopTrack(id: left.id, gain: 0.2); a.autoFader = true
        var b = MultiLoopTrack(id: right.id, gain: 0.6); b.autoFader = true
        var c = MultiLoopTrack(id: ordinary.id, gain: 0); c.autoFader = true
        backend.transport.multiLoop = MultiLoopPlayback(id: UUID(), start: 10, end: 20,
            amount: 0.5, gates: false, released: false, tracks: [a, b, c])
        var audioTargets: [UUID?] = []
        show.audioVolume = { id, _ in audioTargets.append(id) }
        show.tick()
        let legacyWrites = backend.scalarWrites.filter { $0.0 == .volume }
        XCTAssertFalse(legacyWrites.isEmpty)
        XCTAssertTrue(legacyWrites.allSatisfy { $0.1 == left.id || $0.1 == right.id })
        XCTAssertTrue(audioTargets.allSatisfy { $0 == left.id || $0 == right.id })
        XCTAssertLessThan(show.current!.tracks[0].volume, 1)
        XCTAssertEqual(show.current!.tracks[0].volume, show.current!.tracks[1].volume)
        XCTAssertEqual(show.current!.tracks[2].volume, 1, "the compatibility exception does not pull ordinary tracks back into project automation")
        XCTAssertEqual(backend.project.songs[0].tracks[2].volume, 1)
        XCTAssertGreaterThan(show.mixerPlaybackRevision, 0)
        XCTAssertFalse(show.hasUnsavedChanges)
        XCTAssertFalse(show.canUndo)
    }
    @MainActor func testSongTransitionRestoresGatesOnTheSongThatOwnedTheLoop() throws {
        let backend = SectionExecutor()
        var project = Project.empty(name: "Gate ownership across songs")
        let first = Track(id: UUID(), name: "First", role: .keys)
        let second = Track(id: UUID(), name: "Second", role: .keys)
        project.songs[0].tracks = [first]
        var next = project.songs[0]; next.id = UUID(); next.name = "Next"; next.tracks = [second]
        project.songs.append(next)
        let show = try ShowController(executor: backend, persistence: MemoryProjectStore(), initialProject: project)
        var rule = MultiLoopTrack(id: first.id, gain: 0.1)
        rule.autoFader = true; rule.mute = true; rule.solo = true
        backend.transport.multiLoop = MultiLoopPlayback(id: UUID(), start: 10, end: 20,
            amount: 1, gates: true, released: false, tracks: [rule])
        show.tick()
        XCTAssertTrue(show.snapshot.project.songs[0].tracks[0].mute)
        XCTAssertTrue(show.snapshot.project.songs[0].tracks[0].solo)
        backend.transport.songId = next.id; backend.transport.multiLoop = nil
        show.tick()
        XCTAssertEqual(show.snapshot.project, project, "leaving a song restores its temporary gates before forgetting the loop")
        XCTAssertEqual(backend.project, project)
        XCTAssertFalse(backend.commands.contains(.volume))
        XCTAssertFalse(show.hasUnsavedChanges)
        XCTAssertFalse(show.canUndo)
    }
    @MainActor func testReplacingProjectDuringAutoFaderCannotRestorePreviousProjectMixerState() throws {
        try checkLoadingProjectDuringAutoFader(importing: false)
    }
    @MainActor func testImportingProjectDuringAutoFaderCannotRestorePreviousProjectMixerState() throws {
        try checkLoadingProjectDuringAutoFader(importing: true)
    }
    @MainActor private func checkLoadingProjectDuringAutoFader(importing: Bool) throws {
        let backend = SectionExecutor()
        var project = Project.empty(name: "Before reload")
        let track = Track(id: UUID(), name: "Track", role: .keys)
        project.songs[0].tracks = [track]
        let show = try ShowController(executor: backend, persistence: MemoryProjectStore(), initialProject: project)
        defer { show.send(.stopAll) }
        var rule = MultiLoopTrack(id: track.id, gain: 0); rule.autoFader = true
        var master = MultiLoopTrack(id: MultiLoopTrack.masterID, gain: 0); master.autoFader = true
        backend.transport.multiLoop = MultiLoopPlayback(id: UUID(), start: 10, end: 20,
            amount: 0.5, gates: false, released: false, tracks: [rule, master])
        show.tick()
        var replacement = project
        replacement.name = "Reloaded manual state"
        replacement.songs[0].tracks[0].mute = true
        replacement.songs[0].tracks[0].solo = true
        replacement.masterMute = true
        replacement.masterSolo = true
        replacement.masterVolume = 0.7
        // Loading a document resets the core's transient loop, while keeping
        // IDs when the user reloads another saved version of that document.
        backend.transport.multiLoop = nil
        if importing { try show.importProject(ProjectDocumentCodec.encode(replacement)) }
        else { try show.replaceProject(replacement) }
        backend.commands.removeAll()
        show.send(.play)
        XCTAssertEqual(show.snapshot.project, replacement)
        XCTAssertEqual(backend.project, replacement)
        XCTAssertFalse(backend.commands.contains(.mute))
        XCTAssertFalse(backend.commands.contains(.solo))
        XCTAssertFalse(backend.commands.contains(.volume))
        XCTAssertEqual(show.hasUnsavedChanges, importing)
        XCTAssertEqual(show.canUndo, importing)
    }
    @MainActor func testSectionCreationOutsideRegionShowsNotice() throws {
        let show = try ShowController(executor: SectionExecutor(), persistence: MemoryProjectStore(), initialProject: Project.demo())
        XCTAssertFalse(show.canCreateSectionMarker(at: -1))
        XCTAssertEqual(show.modalNotice, "Section markers can only be created inside a song.")
    }
}
