import XCTest
@testable import JarasApplication

final class TimelineSnapTests: XCTestCase {
    func testItemsAndMarkersFollowFourTwoOneBarsThenVisibleSubdivisions() {
        var song = Project.empty(name: "Visible drag grid").songs[0]
        song.bpm = 120; song.duration = 1000; song.parts = []
        var settings = ProjectTimeSettings(); settings.divisions = 8; song.timeSettings = settings
        let marker = TimelineMarker(id: UUID(), name: "Cue", position: 70, color: 0xffffff)
        song.markers = [marker]
        for (scale, target) in [(1.0, 8.0), (2, 12), (4, 10), (8, 10), (32, 10.5), (64, 10.75)] {
            XCTAssertEqual(TimelineTempo.snap(10.74, song: song, pixelsPerSecond: scale,
                maximumDistancePixels: 8), target, accuracy: 1e-9)
            XCTAssertEqual(song.markerDragPosition(marker, to: 10.74, pixelsPerSecond: scale, free: false), target, accuracy: 1e-9)
            XCTAssertEqual(song.markerDragPosition(marker, to: 10.74, pixelsPerSecond: scale, free: true), 10.74)
            let lines = TimelineTimeRuler.ticks(in: song.tempoSections(until: 1000), from: 0, to: 20,
                pixelsPerSecond: scale, divisions: 8)
            XCTAssertTrue(lines.contains { abs($0.time - target) < 1e-9 }, "The snap target must be drawn")
        }
    }
    func testDistantGridDoesNotSnapToHiddenHalfStrideLines() {
        var song = Project.empty(name: "Visible bars").songs[0]
        song.bpm = 120; song.duration = 10000; song.parts = []; song.markers = []
        XCTAssertEqual(TimelineTempo.snap(11.9, song: song, pixelsPerSecond: 1), 8)
        XCTAssertEqual(TimelineTempo.snap(12.1, song: song, pixelsPerSecond: 1), 16)
        XCTAssertEqual(TimelineTempo.snap(12.1, song: song, pixelsPerSecond: 2), 12)
    }
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
            XCTAssertGreaterThanOrEqual(step * scale, 8)
            let major = 2 * Double(TimelineTempo.barStride(bar: 2, pixelsPerSecond: scale))
            XCTAssertGreaterThanOrEqual(major * scale, 8)
            let snapped = TimelineTempo.snap(123.456, bar: 2, beats: 4, pixelsPerSecond: scale)
            XCTAssertEqual(snapped / step, (snapped / step).rounded(), accuracy: 0.000001)
        }
    }
    func testCursorMatchesVisibleGridAcrossTempoAndZoomChanges() {
        var song = Project.empty(name: "Visible subdivisions").songs[0]
        song.bpm = 120; song.duration = 20000; song.parts = []
        var settings = ProjectTimeSettings(); settings.divisions = 8; song.timeSettings = settings
        song.markers = [TimelineMarker(id: UUID(), name: "Tempo", position: 10.13, color: 0xffffff,
            tempoBPM: 150, tempoBeats: 3, tempoUnit: 8)]
        for scale in [0.05, 0.3, 1, 10, 100, 1000] {
            let ticks = TimelineTimeRuler.ticks(in: song.tempoSections(until: 20000), from: 0, to: 2000,
                pixelsPerSecond: scale, divisions: 8)
            for position in [3.29, 10.76, 300.78] {
                let target = TimelineTempo.snap(position, song: song, pixelsPerSecond: scale)
                let explicitAnchor = target == 0 || abs(target - 10.13) < 1e-8
                XCTAssertTrue(explicitAnchor || ticks.contains { abs($0.time - target) < 1e-8 },
                    "Snap \(target) must follow a visible tick or explicit tempo boundary at scale \(scale)")
                XCTAssertEqual(TimelineTempo.snap(position, song: song, pixelsPerSecond: scale, enabled: false), position)
            }
            XCTAssertEqual(TimelineTempo.snap(10.14, song: song, pixelsPerSecond: scale), 10.13, accuracy: 1e-9)
        }
        settings.divisions = 0; song.timeSettings = settings
        XCTAssertEqual(TimelineTempo.snap(3.29, song: song, pixelsPerSecond: 1), 0,
            "Disabling grid divisions retains only explicit anchors")
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

extension TimelineSnapTests {
    func testNearbyCursorAndItemEdgesWinAgainstCloserGridLines() {
        var song = Project.empty(name: "Strong anchors").songs[0]
        song.bpm = 120; song.parts = []; song.markers = []; song.duration = 20
        let item = AudioClip(id: UUID(), name: "Anchor", startTime: 1.09, duration: 1.04)
        var track = Track(id: UUID(), name: "Audio", role: .other); track.clips = [item]; song.tracks = [track]
        XCTAssertEqual(TimelineTempo.snap(1.01, song: song, pixelsPerSecond: 100, includeItemEdges: true),1.09)
        XCTAssertEqual(TimelineTempo.snap(2.01, song: song, pixelsPerSecond: 100, includeItemEdges: true),2.13)
        XCTAssertEqual(TimelineTempo.snap(1.01, song: song, pixelsPerSecond: 100, cursor: 1.1),1.1)
        XCTAssertEqual(TimelineTempo.snap(1.01, song: song, pixelsPerSecond: 100, includeItemEdges: true, excludingItems: [item.id]),1)
        XCTAssertEqual(TimelineTempo.snap(1.01, song: song, pixelsPerSecond: 100, enabled: false, includeItemEdges: true),1.01)
    }
}


extension TimelineSnapTests {
    func testItemDragOutsideMagnetRadiusKeepsItsDropPositionAtDistantZoom() throws {
        var song = Project.empty(name: "Distant drag").songs[0]
        song.parts = []; song.markers = []; song.duration = 10000
        var settings = ProjectTimeSettings(); settings.divisions = 0; song.timeSettings = settings
        let clip = AudioClip(id: UUID(), name: "Moving", startTime: 100, duration: 50)
        var track = Track(id: UUID(), name: "Audio", role: .other); track.clips = [clip]; song.tracks = [track]
        for scale in [0.01, 0.05, 0.3, 1.0, 10.0, 100.0] {
            // This cursor coincides with the original item start. Releasing well
            // outside its magnetic area must not pull the item back there.
            let proposed = clip.startTime + 30 / scale
            let target = TimelineTempo.snap(proposed, song: song, pixelsPerSecond: scale,
                cursor: clip.startTime, includeItemEdges: true, excludingItems: [clip.id], maximumDistancePixels: 8)
            XCTAssertEqual(target, proposed, accuracy: 1e-9, "drag moved 30 screen pixels at scale \(scale)")
            let committed = try XCTUnwrap(song.movingItems([clip.id], anchor: clip.id, start: target, track: track.id))
            XCTAssertEqual(committed.tracks[0].clips[0].startTime, proposed, accuracy: 1e-9,
                           "the actual project move commits the displayed drop position")
        }
    }

    func testItemMagnetExcludesWholeSelectionAndHasOneScreenSpaceRadius() {
        var song = Project.empty(name: "Magnet radius").songs[0]
        song.parts = []; song.markers = []; song.duration = 10000
        var settings = ProjectTimeSettings(); settings.divisions = 0; song.timeSettings = settings
        let first = AudioClip(id: UUID(), name: "First", startTime: 100, duration: 20)
        let second = AudioClip(id: UUID(), name: "Second", startTime: 160, duration: 20)
        let anchor = AudioClip(id: UUID(), name: "Other", startTime: 1000, duration: 50)
        var track = Track(id: UUID(), name: "Audio", role: .other); track.clips = [first, second, anchor]; song.tracks = [track]
        let moving: Set<UUID> = [first.id, second.id]
        for scale in [0.05, 0.3, 1.0, 100.0] {
            let snapped = TimelineTempo.snap(anchor.startTime - 7 / scale, song: song,
                pixelsPerSecond: scale, includeItemEdges: true, excludingItems: moving, maximumDistancePixels: 8)
            XCTAssertEqual(snapped, anchor.startTime, accuracy: 1e-9)
            let free = anchor.startTime - 9 / scale
            XCTAssertEqual(TimelineTempo.snap(free, song: song, pixelsPerSecond: scale,
                includeItemEdges: true, excludingItems: moving, maximumDistancePixels: 8), free, accuracy: 1e-9)
        }
        XCTAssertEqual(TimelineTempo.snap(second.startTime, song: song, pixelsPerSecond: 1,
            includeItemEdges: true, excludingItems: moving, maximumDistancePixels: 8), second.startTime)
        let free = 163.0
        XCTAssertEqual(TimelineTempo.snap(free, song: song, pixelsPerSecond: 1,
            includeItemEdges: true, excludingItems: moving, maximumDistancePixels: 8), free)
        XCTAssertEqual(TimelineTempo.snap(995, song: song, pixelsPerSecond: 1, enabled: false,
            includeItemEdges: true, excludingItems: moving, maximumDistancePixels: 8), 995)
    }

    func testItemDragUsesNearbyGridButDoesNotForceDistantMusicalDivision() {
        var song = Project.empty(name: "Magnetic divisions").songs[0]
        song.bpm = 120; song.parts = []; song.markers = []; song.duration = 100
        XCTAssertEqual(TimelineTempo.snap(1.12, song: song, pixelsPerSecond: 60,
            maximumDistancePixels: 8), 1, accuracy: 1e-9)
        XCTAssertEqual(TimelineTempo.snap(1.24, song: song, pixelsPerSecond: 60,
            maximumDistancePixels: 8), 1.24, accuracy: 1e-9)
        // Plain cursor placement retains its existing division quantization.
        XCTAssertEqual(TimelineTempo.snap(1.24, song: song, pixelsPerSecond: 60), 1, accuracy: 1e-9)
    }
}
