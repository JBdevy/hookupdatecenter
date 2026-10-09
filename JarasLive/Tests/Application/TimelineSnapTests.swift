import XCTest
@testable import JarasApplication

final class TimelineSnapTests: XCTestCase {
    func testFreeCursorPositionIgnoresGridAndEveryMagneticAnchor() {
        for scale in [0.16, 1, 100, 10_000] {
            for position in [30.18, 39.29, 42.13, 123.456789] {
                XCTAssertEqual(TimelineTempo.snap(position, bar: 2, beats: 4, pixelsPerSecond: scale,
                    anchors: [30.15], additionalAnchors: [39.27], cursor: 42.125, enabled: false), position)
            }
        }
        XCTAssertEqual(TimelineTempo.snap(-2, bar: 2, beats: 4, pixelsPerSecond: 100, anchors: [30.15], enabled: false), 0)
        XCTAssertEqual(TimelineTempo.snap(.nan, bar: 2, beats: 4, pixelsPerSecond: 100, anchors: [30.15], enabled: false), 0)
        XCTAssertEqual(TimelineTempo.snap(30.18, bar: 2, beats: 4, pixelsPerSecond: 100, anchors: [30.15]), 30.15,
                       "releasing Shift restores normal snapping")
    }
    func testGridStaysReadableAndSnapMatchesVisibleLinesAcrossZoom() {
        for scale in [0.05, 0.3, 1, 3, 10, 20, 40, 100, 500] {
            let step = TimelineTempo.gridStep(bar: 2, beats: 4, pixelsPerSecond: scale)
            XCTAssertGreaterThanOrEqual(step * scale, 16)
            let major = 2 * Double(TimelineTempo.barStride(bar: 2, pixelsPerSecond: scale))
            XCTAssertGreaterThanOrEqual(major * scale, 16)
            let snapped = TimelineTempo.snap(123.456, bar: 2, beats: 4, pixelsPerSecond: scale)
            XCTAssertEqual(snapped / step, (snapped / step).rounded(), accuracy: 0.000001)
        }
    }
    private func snap(_ time: Double, starts: [Double] = [30.15], ends: [Double]? = nil,
                      cursor: Double? = nil, scale: Double = 100) -> Double {
        TimelineTempo.snap(time, bar: 2, beats: 4, pixelsPerSecond: scale, anchors: starts,
                           additionalAnchors: ends, cursor: cursor)
    }
    func testCursorSnapsToNearbyOffGridRegionStart() {
        XCTAssertEqual(snap(30.18), 30.15)
        XCTAssertEqual(snap(30.09), 30.15)
        XCTAssertEqual(snap(30.24), 30.15, "the nearest anchor wins even outside the old magnetic radius")
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
        XCTAssertEqual(snap(39.38, ends: [39.27]), 39.27)
        XCTAssertEqual(snap(39.28), 39.5, "end anchors are requested only for edge adjustments")
    }
    func testNearestAnchorCompetesWithVisibleGridAcrossZoom() {
        XCTAssertEqual(snap(30.3, scale: 40), 30.15)
        XCTAssertEqual(snap(30.3, scale: 100), 30.15)
        XCTAssertEqual(snap(10, starts: [.nan, .infinity, -1], cursor: .nan), 10)
        XCTAssertEqual(snap(.nan), 0)
    }
    func testAbsoluteAnchorsAndShiftAcrossTempoChanges() {
        var song = Project.empty(name: "Snap").songs[0]
        song.bpm = 120; song.duration = 100
        song.parts = [Part(id: UUID(), name: "Off grid", startTime: 30.15, endTime: 39.27)]
        let normal = TimelineMarker(id: UUID(), name: "Marker", position: 42.17, color: 0xffffff)
        let tempo = TimelineMarker(id: UUID(), name: "Tempo", position: 50.13, color: 0xffffff,
                                   tempoBPM: 180, tempoBeats: 4, tempoUnit: 4)
        song.markers = [normal, tempo]
        for (time, expected) in [(30.24, 30.15), (39.38, 39.27), (42.28, 42.17), (50.10, 50.13)] {
            XCTAssertEqual(TimelineTempo.snap(time, song: song, pixelsPerSecond: 100), expected, accuracy: 1e-9)
            XCTAssertEqual(TimelineTempo.snap(time, song: song, pixelsPerSecond: 100, enabled: false), time)
        }
        XCTAssertEqual(TimelineTempo.snap(44.18, song: song, pixelsPerSecond: 100, cursor: 44.23), 44.23)
        XCTAssertEqual(TimelineTempo.snap(44.18, song: song, pixelsPerSecond: 100,
            cursor: 44.23, otherCursors: [44.15]), 44.15)
        XCTAssertEqual(TimelineTempo.snap(30.24, song: song, pixelsPerSecond: 100,
            excludingRegion: song.parts[0].id), 30)
        XCTAssertEqual(TimelineTempo.snap(42.28, song: song, pixelsPerSecond: 100,
            excludingMarker: normal.id), 42.5)
    }

}
