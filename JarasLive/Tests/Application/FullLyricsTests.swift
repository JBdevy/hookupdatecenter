import XCTest
@testable import JarasApplication

final class FullLyricsTests: XCTestCase {
    func testTwoBlankLinesKeepSingleBlankInsideStanza() {
        XCTAssertEqual(FullLyrics.stanzas("\n\nVerse one\nline two\n\nline four\n \n\t\nChorus\r\nlast line\r\n\r\n"), ["Verse one\nline two\n\nline four", "Chorus\nlast line"])
        XCTAssertEqual(FullLyrics.stanzas("A\n\nB"), ["A\n\nB"])
    }
    func testCursorInsideSongUsesWholeRangeAndExactEnd() throws {
        var song = Project.empty(name: "Lyrics").songs[0]
        song.parts = [.init(id: UUID(), name: "Song", startTime: 20, endTime: 120)]
        let range = try FullLyricsRange(song: song, position: 75)
        let items = try range.items(text: "A\n\n\nB\n\n\nC")
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].startTime, 20)
        XCTAssertEqual(items.last!.startTime + items.last!.duration, 120)
        XCTAssertEqual(items[0].duration, items[1].duration, accuracy: 1e-12)
        XCTAssertEqual(items[1].startTime, items[0].startTime + items[0].duration)
        XCTAssertTrue(items.allSatisfy { $0.regionOwnerID == song.parts[0].id })
        XCTAssertThrowsError(try range.items(text: "A\n\nB"))
        XCTAssertThrowsError(try FullLyricsRange(song: song, position: 120))
    }
    func testUnifiedRegionChoosesInternalSongAtAnyPoint() throws {
        var song = Project.empty(name: "Lyrics").songs[0]
        let parent = Part(id: UUID(), name: "Unified", startTime: 10, endTime: 100)
        var first = Part(id: UUID(), name: "First", startTime: 10, endTime: 50); first.parentRegionID = parent.id
        var second = Part(id: UUID(), name: "Second", startTime: 50, endTime: 100); second.parentRegionID = parent.id
        song.parts = [parent, second, first]
        let range = try FullLyricsRange(song: song, position: 65)
        XCTAssertEqual(range.region, second.id); XCTAssertEqual(range.start, 50); XCTAssertEqual(range.end, 100)
        XCTAssertEqual(try FullLyricsRange(song: song, position: 50), range)
        let firstRange = try FullLyricsRange(song: song, position: 49)
        XCTAssertEqual(firstRange.start, 10); XCTAssertEqual(firstRange.end, 50)
    }
}
