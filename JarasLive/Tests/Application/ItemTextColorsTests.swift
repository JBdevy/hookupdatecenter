import XCTest
@testable import JarasApplication
final class ItemTextColorsTests: XCTestCase {
    func testColoredWordsKeepUnicodeThroughSerialization() throws {
        let source = [ItemTextColors.Run(text: "É 🎵 "), .init(text: "Am7\nRé", color: 0xff4040), .init(text: " <script> literal")]
        let encoded = ItemTextColors.encode(source)
        XCTAssertEqual(ItemTextColors.runs(encoded), source)
        XCTAssertEqual(ItemTextColors.plain(encoded), "É 🎵 Am7\nRé <script> literal")
        let saved = try JSONEncoder().encode(encoded)
        XCTAssertEqual(ItemTextColors.runs(try JSONDecoder().decode(String.self, from: saved)), source)
        XCTAssertEqual(ItemTextColors.encode([.init(text: "Am\nG")]), "Am\nG")
    }
    func testColumnsPreserveIndependentColorsAndEmptySecondColumn() throws {
        let first = ItemTextColors.encode([.init(text: "Primeira 🎵", color: 0xff4040)])
        let second = ItemTextColors.encode([.init(text: "Segunda\nRé", color: 0x54ef86)])
        let value = ItemTextColors.encodeColumns([first, second])
        XCTAssertEqual(ItemTextColors.columns(value), [first, second])
        XCTAssertEqual(ItemTextColors.plain(value), "Primeira 🎵\nSegunda\nRé")
        XCTAssertEqual(ItemTextColors.columns(ItemTextColors.encodeColumns([first, ""])), [first, ""])
        let saved = try JSONEncoder().encode(value)
        XCTAssertEqual(ItemTextColors.columns(try JSONDecoder().decode(String.self, from: saved)), [first, second])
        XCTAssertEqual(ItemTextColors.columns("Legacy text"), ["Legacy text"])
        let malformed = ItemTextColors.columnsPrefix + "[1,2]"
        XCTAssertEqual(ItemTextColors.columns(malformed), [malformed])
        let nested = ItemTextColors.encodeColumns([value, ""])
        XCTAssertEqual(ItemTextColors.columns(nested), [nested])
    }
    func testMalformedFormattingStaysLiteralAndColorsMerge() {
        for invalid in ["not json", "[{\"text\":\"Am\",\"color\":16777216}]", "[{\"text\":\"Am\",\"color\":-1}]"] {
            let text = ItemTextColors.prefix + invalid
            XCTAssertEqual(ItemTextColors.plain(text), text)
        }
        XCTAssertEqual(ItemTextColors.runs(ItemTextColors.encode([.init(text: "A", color: 0x54ef86), .init(text: "m", color: 0x54ef86)])), [.init(text: "Am", color: 0x54ef86)])
    }
}
