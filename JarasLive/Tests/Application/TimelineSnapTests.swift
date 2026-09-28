import XCTest
@testable import JarasApplication

final class TimelineSnapTests: XCTestCase {
    private func snap(_ time: Double, starts: [Double] = [30.15], ends: [Double]? = nil,
                      cursor: Double? = nil, scale: Double = 100) -> Double {
        TimelineTempo.snap(time, bar: 2, beats: 4, pixelsPerSecond: scale, anchors: starts,
                           additionalAnchors: ends, cursor: cursor)
    }
    func testCursorSnapsToNearbyOffGridRegionStart() {
        XCTAssertEqual(snap(30.18), 30.15)
        XCTAssertEqual(snap(30.09), 30.15)
        XCTAssertEqual(snap(30.24), 30, "outside the magnetic area, drawn grid divisions still win")
        XCTAssertEqual(snap(-2), 0)
    }
    func testItemPlacementSnapsToRegionOrEditingNeedle() {
        XCTAssertEqual(snap(42.13, cursor: 42.125), 42.125)
        XCTAssertEqual(snap(30.145, cursor: 30.11), 30.15, "the nearest anchor wins")
        XCTAssertEqual(snap(41.3, cursor: 42.125), 41.5)
    }
    func testBothRegionEdgesCatchItemResize() {
        XCTAssertEqual(snap(39.29, ends: [39.27]), 39.27)
        XCTAssertEqual(snap(30.13, ends: [39.27]), 30.15)
        XCTAssertEqual(snap(39.38, ends: [39.27]), 39.5)
        XCTAssertEqual(snap(39.28), 39.5, "end anchors are requested only for edge adjustments")
    }
    func testToleranceIsConstantOnScreenAcrossZoom() {
        XCTAssertEqual(snap(30.3, scale: 40), 30.15)
        XCTAssertEqual(snap(30.3, scale: 100), 30.5)
        XCTAssertEqual(snap(10, starts: [.nan, .infinity, -1], cursor: .nan), 10)
        XCTAssertEqual(snap(.nan), 0)
    }
}
