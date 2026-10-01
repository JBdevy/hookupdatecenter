import XCTest
@testable import JarasApplication
final class MultiLoopTests: XCTestCase {
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
    func testOnlyManualMarkersInsideNormalOrDrawerSong() {
        var song = Project.demo().songs[0]
        let region = Part(id: UUID(), name: "Song", startTime: 5, endTime: 20, parentRegionID: UUID())
        let start = TimelineMarker(id: UUID(), name: "Start", position: 5, color: 0)
        let end = TimelineMarker(id: UUID(), name: "End", position: 20, color: 0)
        var converted = start; converted.id = UUID(); converted.sourceRegionID = UUID()
        var tempo = end; tempo.id = UUID(); tempo.tempoBPM = 120
        var outside = end; outside.id = UUID(); outside.position = 21
        song.markers = [outside, tempo, end, converted, start]
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
