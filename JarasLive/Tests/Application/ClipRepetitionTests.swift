import XCTest
@testable import JarasApplication

final class ClipRepetitionTests: XCTestCase {
    private func clip(start: Double = 30, duration: Double = 35, offset: Double = 0, rate: Double = 1) -> AudioClip {
        AudioClip(id: UUID(), name: "Repeated", startTime: start, duration: duration,
                  sourceOffset: offset, playbackRate: rate, loopStart: 0, loopLength: 10)
    }
    func testRightExtensionMarksEachReturnToBeginning() {
        XCTAssertEqual(Array(ClipRepetitionBoundaries(clip: clip(), visible: 0...100)), [40,50,60])
        XCTAssertEqual(Array(ClipRepetitionBoundaries(clip: clip(duration: 10), visible: 0...100)), [])
    }
    func testLeftExtensionMarksOriginalBeginningAndLaterRepeats() {
        XCTAssertEqual(Array(ClipRepetitionBoundaries(clip: clip(start: 25, duration: 40, offset: 5), visible: 0...100)), [30,40,50,60])
        XCTAssertEqual(Array(ClipRepetitionBoundaries(clip: clip(start: 18, duration: 47, offset: 8), visible: 0...100)), [20,30,40,50,60])
    }
    func testVisibleRangeAndTempoStayAlignedWithSource() {
        XCTAssertEqual(Array(ClipRepetitionBoundaries(clip: clip(), visible: 45...55)), [50])
        XCTAssertEqual(Array(ClipRepetitionBoundaries(clip: clip(duration: 15, rate: 2), visible: 0...100)), [35,40])
        XCTAssertEqual(Array(ClipRepetitionBoundaries(clip: clip(), visible: 0...100, minimumSpacing: 21)), [40])
    }
    func testNormalItemsAndTimecodeHaveNoLoopSeam() {
        let plain = AudioClip(id: UUID(), name: "MTC", startTime: 30, duration: 100)
        XCTAssertTrue(Array(ClipRepetitionBoundaries(clip: plain, visible: 0...100)).isEmpty)
    }
}
