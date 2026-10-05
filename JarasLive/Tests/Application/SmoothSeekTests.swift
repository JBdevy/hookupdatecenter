import XCTest
import Combine
@testable import JarasApplication

@MainActor private final class SectionExecutor: CommandExecutor {
    var project = Project.demo()
    var transport = TransportState(playing: true, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0))
    var commands: [ShowCommand] = []
    func load(_ project: Project) throws { self.project = project; transport.songId = project.songs[0].id }
    func snapshot() throws -> ShowSnapshot { ShowSnapshot(project: project, transport: transport) }
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: transport) }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws {
        commands.append(command)
        if command == .escape, transport.queuedSectionMarkerId != nil {
            transport.queuedSectionMarkerId = nil; transport.sectionQueueStartedAt = nil
            return
        }
        guard let t = project.songs[0].tracks.firstIndex(where: { $0.id == target }) else { return }
        switch command {
        case .volume: project.songs[0].tracks[t].volume = value
        case .mute: project.songs[0].tracks[t].mute.toggle()
        case .solo: project.songs[0].tracks[t].solo.toggle()
        default: break
        }
    }
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
    @MainActor func testLoopAutomationUsesRealMixerCommandsAndRestoresControls() throws {
        let backend = SectionExecutor()
        let show = try ShowController(executor: backend, persistence: MemoryProjectStore(), initialProject: Project.demo())
        let track = show.current!.tracks[0]
        var rule = MultiLoopTrack(id: track.id, gain: 0.2)
        rule.autoFader = true; rule.solo = true; rule.mute = true
        backend.transport.multiLoop = MultiLoopPlayback(id: UUID(), start: 10, end: 20, amount: 0.5, gates: false, released: false, tracks: [rule])
        let revision = show.projectRevision
        show.tick()
        XCTAssertGreaterThan(show.mixerPlaybackRevision, 0)
        XCTAssertEqual(show.projectRevision, revision, "fader animation does not invalidate waveform geometry")
        XCTAssertEqual(show.current!.tracks[0].volume, 0.6, accuracy: 0.000001)
        XCTAssertEqual(backend.project.songs[0].tracks[0].volume, 0.6, accuracy: 0.000001)
        XCTAssertFalse(show.current!.tracks[0].solo)
        backend.transport.multiLoop!.amount = 1; backend.transport.multiLoop!.gates = true
        show.tick()
        XCTAssertEqual(show.current!.tracks[0].volume, 0.2, accuracy: 0.000001)
        XCTAssertTrue(show.current!.tracks[0].solo)
        XCTAssertTrue(show.current!.tracks[0].mute)
        XCTAssertTrue(backend.commands.contains(.volume)); XCTAssertTrue(backend.commands.contains(.mute)); XCTAssertTrue(backend.commands.contains(.solo))
        backend.transport.multiLoop = nil
        show.tick()
        XCTAssertEqual(show.current!.tracks[0].volume, track.volume, accuracy: 0.000001)
        XCTAssertEqual(show.current!.tracks[0].solo, track.solo)
        XCTAssertEqual(show.current!.tracks[0].mute, track.mute)
    }
    @MainActor func testManyAutoFadersPublishOneMixerFrameAndRestore() throws {
        let backend = SectionExecutor()
        var project = Project.demo()
        let original = project.songs[0].tracks[0]
        project.songs[0].tracks = (0..<24).map { index in
            var track = original; track.id = UUID(); track.name = "Fade \(index)"
            track.stereoLink = nil; track.parentTrackID = nil; track.volume = 1; track.mute = false; track.solo = false
            return track
        }
        let show = try ShowController(executor: backend, persistence: MemoryProjectStore(), initialProject: project)
        let rules = project.songs[0].tracks.map { track in
            var rule = MultiLoopTrack(id: track.id, gain: 0); rule.autoFader = true; return rule
        }
        var publications = 0
        let observation = show.projectPresentation.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        var gains: [UUID: Double] = [:]
        show.audioVolume = { id, gain in if let id { gains[id] = gain } }
        backend.transport.multiLoop = MultiLoopPlayback(id: UUID(), start: 10, end: 20,
            amount: 0.5, gates: false, released: false, tracks: rules)
        let revision = show.projectRevision
        show.tick()
        XCTAssertEqual(publications, 1, "24 automatic faders publish one complete mixer frame")
        XCTAssertEqual(gains.count, 24)
        XCTAssertTrue(gains.values.allSatisfy { abs($0 - 0.5) < 0.000001 })
        XCTAssertTrue(show.current!.tracks.allSatisfy { abs($0.volume - 0.5) < 0.000001 })
        XCTAssertTrue(backend.project.songs[0].tracks.allSatisfy { abs($0.volume - 0.5) < 0.000001 })
        XCTAssertEqual(show.projectRevision, revision)
        backend.transport.multiLoop = nil; show.tick()
        XCTAssertEqual(publications, 2)
        XCTAssertTrue(show.current!.tracks.allSatisfy { $0.volume == 1 })
    }
    @MainActor func testSectionCreationOutsideRegionShowsNotice() throws {
        let show = try ShowController(executor: SectionExecutor(), persistence: MemoryProjectStore(), initialProject: Project.demo())
        XCTAssertFalse(show.canCreateSectionMarker(at: -1))
        XCTAssertEqual(show.modalNotice, "Section markers can only be created inside a song.")
    }
}
