import XCTest
@testable import JarasApplication

final class PlaybackSchedulingIndexTests: XCTestCase {
    func testSchedulingIndexMatchesOriginalScanAtOverlapsEdgesLoopsAndBackwardSeeks() {
        var clips: [AudioClip] = []
        for number in (0..<600).reversed() {
            let start = Double(number % 100) * 4
            let duration = number % 17 == 0 ? 500.0 : Double(number % 11 + 1)
            var clip = AudioClip(id: UUID(), name: "Take \(number)", startTime: start, duration: duration)
            if number % 13 == 0 { clip.loopLength = 1 }
            clips.append(clip)
        }
        clips.append(AudioClip(id: UUID(), name: "Short", startTime: 2, duration: 0.001))
        clips.append(AudioClip(id: UUID(), name: "At lookahead", startTime: 4, duration: 3))
        let index = AudioClipPlaybackIndex(clips: clips)
        let positions = [-2, 0, 2, 2.001, 4, 7, 120, 500, 1000] + (0..<1000).map { Double(($0 * 137) % 9000) / 10 }
        for position in positions {
            for lookahead in [0.0, 0.01, 2, 20] {
                let expected = clips.indices.filter { clips[$0].startTime <= position + lookahead && clips[$0].startTime + clips[$0].duration > position }
                XCTAssertEqual(index.candidates(at: position, lookahead: lookahead), expected,
                    "Scheduling must preserve source order and both boundary rules at \(position)")
            }
        }
        XCTAssertEqual(AudioClipPlaybackIndex(clips: []).candidates(at: 0), [])
        XCTAssertTrue(index.candidates(at: Double.nan).isEmpty)
    }
    func testRebuildingIndexReflectsItemMoveTrimAndNewTake() {
        var clips = [AudioClip(id: UUID(), name: "Recorded", startTime: 30, duration: 5)]
        XCTAssertEqual(AudioClipPlaybackIndex(clips: clips).candidates(at: 10), [])
        clips[0].startTime = 10
        XCTAssertEqual(AudioClipPlaybackIndex(clips: clips).candidates(at: 10), [0])
        clips[0].duration = 0.5
        XCTAssertEqual(AudioClipPlaybackIndex(clips: clips).candidates(at: 11), [])
        clips.append(AudioClip(id: UUID(), name: "New take", startTime: 11, duration: 1))
        XCTAssertEqual(AudioClipPlaybackIndex(clips: clips).candidates(at: 11), [1])
    }
}
