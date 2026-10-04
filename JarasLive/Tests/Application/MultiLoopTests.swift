import XCTest
@testable import JarasApplication
@MainActor private final class MultiLoopTestExecutor: CommandExecutor {
    var project = Project.empty(name: "Loops")
    func load(_ project: Project) throws { self.project = project }
    func snapshot() throws -> ShowSnapshot {
        ShowSnapshot(project: project, transport: TransportState(playing: false, songId: project.songs[0].id, position: 0,
            queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    }
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: try snapshot().transport) }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws {}
    func addTrack(id: UUID, name: String, role: TrackRole) throws {}
    func advance(_ elapsed: Double) {}
    func finishCurrentSong(_ enabled: Bool) {}
    func applyProjectEdit(_ project: Project) throws { try project.validate(); self.project = project }
}
final class MultiLoopTests: XCTestCase {
    @MainActor func testImportedOverlappingPairsAndSharedDrawerAnchorRemainEditable() throws {
        var project = Project.empty(name: "VS Hook slots")
        let parent = Part(id: UUID(), name: "Special", startTime: 0, endTime: 30)
        var child = Part(id: UUID(), name: "Song", startTime: 5, endTime: 25, parentRegionID: parent.id)
        let start = TimelineMarker(id: UUID(), name: "Song", position: 5, color: 0, unifiedRegionID: parent.id, sourceRegionID: child.id)
        let middle = TimelineMarker(id: UUID(), name: "*2 start", position: 10, color: 0)
        let end = TimelineMarker(id: UUID(), name: "*1 end", position: 15, color: 0)
        let last = TimelineMarker(id: UUID(), name: "*2 end", position: 20, color: 0)
        let unusedFlag = TimelineMarker(id: UUID(), name: "Unused", position: 22, color: 0, unifiedRegionID: parent.id, sourceRegionID: child.id)
        var first = MultiLoop(name: "*1", marker1: start.id, marker2: end.id)
        let second = MultiLoop(name: "*2", marker1: middle.id, marker2: last.id)
        first.enabled = false; child.multiLoops = [first, second]
        project.songs[0].duration = 30
        project.songs[0].parts = [parent, child]
        project.songs[0].markers = [start, middle, end, last, unusedFlag]
        let show = try ShowController(executor: MultiLoopTestExecutor(), persistence: MemoryProjectStore(), initialProject: project)
        XCTAssertTrue(show.current!.multiLoopMarkers(in: child).contains { $0.id == start.id })
        XCTAssertFalse(show.current!.multiLoopMarkers(in: child).contains { $0.id == unusedFlag.id })
        first.enabled = true
        XCTAssertFalse(show.setMultiLoops([first, second], region: parent.id), "Special region is only a container for drawer songs")
        XCTAssertTrue(show.setMultiLoops([first, second], region: child.id))
        first.enabled = false; first.fadeSeconds = 4; first.mixerEnabled = false
        XCTAssertTrue(show.setMultiLoops([first, second], region: child.id))
        XCTAssertEqual(show.current?.parts.first { $0.id == child.id }?.multiLoops, [first, second])
        let newOverlap = MultiLoop(name: "New", marker1: middle.id, marker2: end.id)
        XCTAssertFalse(show.setMultiLoops([first, second, newOverlap], region: child.id))
        var movedPair = first; movedPair.marker2 = last.id
        XCTAssertFalse(show.setMultiLoops([movedPair, second], region: child.id))
    }
    func testImportedActivationAndMixerStatePersistWithoutChangingLegacyDefaults() throws {
        var loop = MultiLoop(name: "*1", marker1: UUID(), marker2: UUID())
        let legacy = try JSONDecoder().decode(MultiLoop.self, from: JSONEncoder().encode(loop))
        XCTAssertNil(legacy.enabled)
        XCTAssertNil(legacy.mixerEnabled)
        XCTAssertTrue(legacy.isEnabled)
        XCTAssertTrue(legacy.usesMixer)
        var rule = MultiLoopTrack(id: UUID(), gain: 0.2)
        rule.autoFader = true; rule.mute = true
        loop.tracks = [rule]
        loop.enabled = false; loop.mixerEnabled = false
        let saved = try JSONDecoder().decode(MultiLoop.self, from: JSONEncoder().encode(loop))
        XCTAssertFalse(saved.isEnabled)
        XCTAssertFalse(saved.usesMixer)
        XCTAssertEqual(saved.tracks, [rule], "disabled loops retain their saved mixer presets")
        loop.enabled = true; loop.mixerEnabled = true
        let enabled = try JSONDecoder().decode(MultiLoop.self, from: JSONEncoder().encode(loop))
        XCTAssertTrue(enabled.isEnabled)
        XCTAssertTrue(enabled.usesMixer)
    }
    func testTotalLoopPersistsWithoutDeletingSavedLoopsAndRejectsOverlappingPairs() throws {
        var song = Project.empty(name: "Loops").songs[0]
        let a = TimelineMarker(id: UUID(), name: "A", position: 1, color: 0)
        let b = TimelineMarker(id: UUID(), name: "B", position: 10, color: 0)
        let c = TimelineMarker(id: UUID(), name: "C", position: 5, color: 0)
        let d = TimelineMarker(id: UUID(), name: "D", position: 15, color: 0)
        song.markers = [a,b,c,d]
        let loop = MultiLoop(name: "First", marker1: a.id, marker2: b.id)
        song.parts = [Part(id: UUID(), name: "Song", startTime: 0, endTime: 20, multiLoops: [loop], totalLoop: true)]
        let saved = try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(song))
        XCTAssertTrue(saved.multiLoopsBypassed(in: saved.parts[0]))
        XCTAssertEqual(saved.parts[0].multiLoops, [loop])
        XCTAssertTrue(song.multiLoopConflicts(MultiLoop(name: "Nested", marker1: c.id, marker2: b.id)))
        XCTAssertTrue(song.multiLoopConflicts(MultiLoop(name: "Crossing", marker1: c.id, marker2: d.id)))
        XCTAssertTrue(song.multiLoopConflicts(MultiLoop(name: "Containing", marker1: a.id, marker2: d.id)))
        XCTAssertFalse(song.multiLoopConflicts(MultiLoop(name: "Adjacent", marker1: b.id, marker2: d.id)))
        XCTAssertFalse(song.multiLoopConflicts(loop), "editing the same loop does not conflict with itself")
        song.parts[0].totalLoop = false
        XCTAssertFalse(song.multiLoopsBypassed(in: song.parts[0]))
        XCTAssertEqual(song.parts[0].multiLoops, [loop])
    }
    func testOnlyStarSectionMarkersInsideNormalOrDrawerSong() {
        var song = Project.demo().songs[0]
        let region = Part(id: UUID(), name: "Song", startTime: 5, endTime: 20, parentRegionID: UUID())
        let start = TimelineMarker(id: UUID(), name: "Start", position: 5, color: 0, section: true, loopSection: true)
        let end = TimelineMarker(id: UUID(), name: "End", position: 20, color: 0, section: true, loopSection: true)
        var converted = start; converted.id = UUID(); converted.sourceRegionID = UUID(); converted.section = nil
        var tempo = end; tempo.id = UUID(); tempo.tempoBPM = 120
        var outside = end; outside.id = UUID(); outside.position = 21
        let dollar = TimelineMarker(id: UUID(), name: "Verse", position: 8, color: 0, section: true)
        song.markers = [outside, tempo, end, converted, start, dollar]
        XCTAssertEqual(song.sectionMarkers(in: region).map(\.id), [start.id, dollar.id, end.id])
        XCTAssertEqual(song.multiLoopMarkers(in: region).map(\.id), [start.id, end.id])
    }
    func testFadeNeverBoostsAndRestoresOriginal() {
        var rule = MultiLoopTrack(id: UUID(), gain: 0.2); rule.autoFader = true
        var state = MultiLoopPlayback(id: UUID(), start: 10, end: 20, amount: 0.5, gates: false, released: false, tracks: [rule])
        XCTAssertEqual(state.gain(1, rule: rule), 0.6, accuracy: 1e-9)
        XCTAssertEqual(state.gain(0.1, rule: rule), 0.1)
        state.amount = 1; XCTAssertEqual(state.gain(1, rule: rule), 0.2, accuracy: 1e-9)
        state.amount = 0; XCTAssertEqual(state.gain(1, rule: rule), 1)
        XCTAssertEqual(state.gain(1, rule: nil), 1)
    }
    func testValidationAndPersistence() throws {
        var loop = MultiLoop(name: "Loop", marker1: UUID(), marker2: UUID())
        try loop.validate()
        XCTAssertEqual(try JSONDecoder().decode(MultiLoop.self, from: JSONEncoder().encode(loop)), loop)
        loop.name = " \n"; XCTAssertThrowsError(try loop.validate())
        loop.name = "Loop"; loop.marker2 = loop.marker1; XCTAssertThrowsError(try loop.validate())
        loop.marker2 = UUID(); loop.fadeSeconds = 6; XCTAssertThrowsError(try loop.validate())
    }
}
