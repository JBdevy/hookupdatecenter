import XCTest
@testable import JarasApplication

final class TimelineMarkerTests: XCTestCase {
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
