import XCTest
@testable import JarasApplication

final class ClipRepetitionTests: XCTestCase {
    func testAudioExtensionUsesRealFileEOFAndDoesNotRepeatTheTrimmedLength() {
        let original = AudioClip(id: UUID(), name: "Trimmed", startTime: 0, duration: 3, sourceOffset: 2,
                                 audioFile: AudioFile(path: "Stems/source.wav"))
        let within = original.resized(start: 0, end: 7, sourceDuration: 10)
        XCTAssertEqual(within.loopLength, 10)
        XCTAssertEqual(Array(ClipRepetitionBoundaries(clip: within, visible: 0...100)), [])
        let extended = original.resized(start: 0, end: 23, sourceDuration: 10)
        XCTAssertEqual(Array(ClipRepetitionBoundaries(clip: extended, visible: 0...100)), [8,18])
        XCTAssertEqual(extended.sourceOffset, 2)
        XCTAssertEqual(extended.resized(start: 0, end: 23, sourceDuration: 80).loopLength, 10, "Imported loop sections retain their own period")
        XCTAssertNil(original.resized(start: 0, end: 23).loopLength, "Missing metadata must not guess a period from the trimmed length")
    }
    func testAudioRepetitionAfterTempoChangeUsesFileLengthInSourceSeconds() {
        var song = Project.empty(name: "Source repeats").songs[0]
        song.bpm = 120; song.timeSettings = ProjectTimeSettings(); song.timeSettings?.timebase = .relative
        song.markers = [.init(id: UUID(), name: "Tempo", position: 0, color: 0, tempoBPM: 240, tempoTimebase: .relative, tempoReferenceBPM: 120)]
        let original = AudioClip(id: UUID(), name: "File", startTime: 0, duration: 5, audioFile: AudioFile(path: "Stems/source.wav"))
        let extended = original.resized(start: 0, end: 13, sourceDuration: 10)
        XCTAssertEqual(ClipRepetitionBoundaries.positions(clip: extended, fragments: song.tempoAudioSegments(extended), visible: 0...100), [5,10])
    }
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
    func testSlowedItemUsesSourceTimeForSeamsAcrossTempoChanges() {
        let item = clip(start: 0, duration: 15)
        let fragments = [clip(start: 0, duration: 5), clip(start: 5, duration: 10, offset: 5, rate: 0.5)]
        XCTAssertEqual(ClipRepetitionBoundaries.positions(clip: item, fragments: fragments, visible: 0...100), [])
        let repeated = clip(start: 0, duration: 25)
        let repeatedFragments = [fragments[0], clip(start: 5, duration: 20, offset: 5, rate: 0.5)]
        XCTAssertEqual(ClipRepetitionBoundaries.positions(clip: repeated, fragments: repeatedFragments, visible: 0...100), [15])
    }
    func testSeamOnTempoBoundaryAppearsOnce() {
        let item = clip(start: 0, duration: 30)
        let fragments = [clip(start: 0, duration: 10), clip(start: 10, duration: 20, offset: 10, rate: 0.5)]
        XCTAssertEqual(ClipRepetitionBoundaries.positions(clip: item, fragments: fragments, visible: 0...100), [10])
    }

}
