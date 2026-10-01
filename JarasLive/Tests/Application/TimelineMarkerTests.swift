import XCTest
@testable import JarasApplication

final class TimelineMarkerTests: XCTestCase {
    func testLeftFacingTempoHeadsUseTheSpaceBeforeTheirOwnLine() {
        let origin = TimelineMarker(id: UUID(), name: "Tempo", position: 0, color: 0x999999, tempoBPM: 120)
        let first = TimelineMarker(id: UUID(), name: "Tempo", position: 10, color: 0x999999, tempoBPM: 120)
        let second = TimelineMarker(id: UUID(), name: "Tempo", position: 12, color: 0x999999, tempoBPM: 120)
        let measured = [origin.id: 50.0, first.id: 50.0, second.id: 50.0]
        let heads = TimelineMarker.flagWidths([second, origin, first], scale: 20, widths: measured, facesLeft: true)
        XCTAssertEqual(heads[origin.id], 60)
        XCTAssertEqual(heads[first.id], 60)
        XCTAssertEqual(heads[second.id], 37)
        XCTAssertGreaterThanOrEqual(10 * 20 - heads[first.id]!, heads[origin.id]! + 3)
        XCTAssertEqual(12 * 20 - heads[second.id]!, 10 * 20 + 3)
    }
    func testLastFlagNeverCrossesItsNormalOrUnifiedRegionEnd() {
        var song = Project.empty(name: "Flags").songs[0]
        let ordinary = Part(id: UUID(), name: "Normal", startTime: 10, endTime: 15)
        let special = Part(id: UUID(), name: "Special", startTime: 20, endTime: 30)
        let child = Part(id: UUID(), name: "Child", startTime: 25, endTime: 30, parentRegionID: special.id)
        let normalMarker = TimelineMarker(id: UUID(), name: "Normal", position: 14, color: 0x55ff99)
        let unifiedMarker = TimelineMarker(id: UUID(), name: "Child", position: 29, color: 0x55ff99, unifiedRegionID: special.id, sourceRegionID: child.id)
        let outside = TimelineMarker(id: UUID(), name: "Outside", position: 40, color: 0x55ff99)
        song.parts = [ordinary, special, child]; song.markers = [normalMarker, unifiedMarker, outside]
        let measured = Dictionary(uniqueKeysWithValues: song.markers!.map { ($0.id, 140.0) })
        let result = TimelineMarker.flagWidths(song.markers!, scale: 50, widths: measured, regionEnds: song.markerRegionEnds)
        XCTAssertEqual(result[normalMarker.id], 50)
        XCTAssertEqual(result[unifiedMarker.id], 50)
        XCTAssertEqual(result[outside.id], 150, "an independent marker outside every region keeps its normal flag")
        let distant = TimelineMarker.flagWidths(song.markers!, scale: 10, widths: measured, regionEnds: song.markerRegionEnds)
        XCTAssertNil(distant[normalMarker.id]); XCTAssertNil(distant[unifiedMarker.id])
        XCTAssertEqual(distant[outside.id], 150)
    }
    func testNamesYieldToRightMarkerAndReappearWithZoom() {
        let left = TimelineMarker(id: UUID(), name: "Entrada", position: 10, color: 0x00ff00)
        let right = TimelineMarker(id: UUID(), name: "Refrão", position: 12, color: 0xffff00)
        let widths = [left.id: 50.0, right.id: 50.0]
        XCTAssertEqual(Set(TimelineMarker.flagWidths([right, left], scale: 10, widths: widths).keys), [right.id])
        XCTAssertEqual(Set(TimelineMarker.flagWidths([right, left], scale: 50, widths: widths).keys), [left.id, right.id])
        XCTAssertEqual(TimelineMarker.flagWidths([left, right], scale: 20, widths: widths)[left.id], 37)
        XCTAssertEqual(TimelineMarker.flagWidths([left, right], scale: 50, widths: widths)[left.id], 60)
        var coincident = right; coincident.position = left.position
        XCTAssertEqual(Set(TimelineMarker.flagWidths([left, coincident], scale: 100, widths: widths).keys), [right.id])
    }
    func testMarkerPersistsWithUnicodeNameAndRejectsInvalidValues() throws {
        var project = Project.empty(name: "Markers")
        let marker = TimelineMarker(id: UUID(), name: "áéíóú1234567", position: 30, color: 0xffaa00)
        project.songs[0].markers = [marker]
        try project.validate()
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(decoded.songs[0].markers, [marker])
        project.songs[0].markers?[0].name += "8"
        XCTAssertThrowsError(try project.validate())
        project.songs[0].markers = [marker]
        project.songs[0].markers?[0].position = -1
        XCTAssertThrowsError(try project.validate())
    }
}
