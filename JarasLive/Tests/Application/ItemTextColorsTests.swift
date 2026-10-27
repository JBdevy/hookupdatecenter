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
    func testMalformedFormattingStaysLiteralAndColorsMerge() {
        for invalid in ["not json", "[{\"text\":\"Am\",\"color\":16777216}]", "[{\"text\":\"Am\",\"color\":-1}]"] {
            let text = ItemTextColors.prefix + invalid
            XCTAssertEqual(ItemTextColors.plain(text), text)
        }
        XCTAssertEqual(ItemTextColors.runs(ItemTextColors.encode([.init(text: "A", color: 0x54ef86), .init(text: "m", color: 0x54ef86)])), [.init(text: "Am", color: 0x54ef86)])
    }
}
