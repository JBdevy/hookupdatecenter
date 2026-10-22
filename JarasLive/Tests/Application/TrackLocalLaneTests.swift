import XCTest
@testable import JarasApplication

final class TrackLocalLaneTests: XCTestCase {
    private func clip(_ name: String, _ start: Double, _ duration: Double, take: Int? = nil) -> AudioClip {
        AudioClip(id: UUID(), name: name, startTime: start, duration: duration, recordingLane: take)
    }
    func testIndependentOverlapComponentsUseOnlyTheirOwnHeight() {
        let isolated = clip("Full height", 0, 5)
        let pair = [clip("Pair A", 10, 5), clip("Pair B", 11, 4)]
        let triple = [clip("Triple A", 30, 10), clip("Triple B", 31, 5), clip("Triple C", 32, 6)]
        var track = Track(id: UUID(), name: "Audio", role: .other)
        track.clips = triple + [isolated] + pair
        let layout = TrackLanes(track: track)
        XCTAssertEqual(layout.count, 3)
        XCTAssertEqual(layout.localCount(for: isolated.id), 1)
        XCTAssertEqual(layout.localLane(for: isolated.id), 0)
        for item in pair { XCTAssertEqual(layout.localCount(for: item.id), 2) }
        for item in triple { XCTAssertEqual(layout.localCount(for: item.id), 3) }
        XCTAssertEqual(Set(pair.map { layout.localLane(for: $0.id) }), [0, 1])
        XCTAssertEqual(Set(triple.map { layout.localLane(for: $0.id) }), [0, 1, 2])
        track.clips.reverse()
        XCTAssertEqual(TrackLanes(track: track), layout, "storage order cannot alter drawing or hit targets")
    }
    func testTouchingEdgesReleaseHeightAndConnectedChainStaysStable() {
        let a = clip("Long", 0, 10), b = clip("First overlap", 1, 2), c = clip("Later overlap", 8, 4)
        let adjacent = clip("Touching", 12.0.nextDown, 3)
        var track = Track(id: UUID(), name: "Audio", role: .other)
        track.clips = [a, b, c, adjacent]
        let layout = TrackLanes(track: track)
        for item in [a, b, c] { XCTAssertEqual(layout.localCount(for: item.id), 2) }
        XCTAssertEqual(layout.localLane(for: b.id), layout.localLane(for: c.id))
        XCTAssertEqual(layout.localCount(for: adjacent.id), 1)
        track.clips[3].startTime = 11.99
        XCTAssertEqual(TrackLanes(track: track).localCount(for: adjacent.id), 2)
    }
    func testCompletedTakesCompactLocallyAndActiveReservationPreservesLanes() {
        let base = clip("Base", 10, 10), take = clip("Take", 9, 3, take: 1)
        let unrelated = clip("Later MIDI", 40, 2, take: 12)
        var track = Track(id: UUID(), name: "Audio", role: .other)
        track.clips = [base, take, unrelated]
        var layout = TrackLanes(track: track)
        XCTAssertEqual(layout.localLane(for: base.id), 0)
        XCTAssertEqual(layout.localLane(for: take.id), 1)
        XCTAssertEqual(layout.localCount(for: unrelated.id), 1)
        layout.reserveRecordingLanes(count: 3)
        for item in track.clips {
            XCTAssertEqual(layout.localCount(for: item.id), 3)
            XCTAssertEqual(layout.localLane(for: item.id), layout.lanes[item.id])
        }
        XCTAssertEqual(TrackLanes(track: track).localCount(for: unrelated.id), 1, "Stop rebuild restores local geometry")
    }
}
