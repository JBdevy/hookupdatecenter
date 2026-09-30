import XCTest
@testable import JarasApplication
final class MultiLoopTests: XCTestCase {
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
