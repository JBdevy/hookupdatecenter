import XCTest
@testable import JarasApplication

final class TimecodeItemSpanTests: XCTestCase {
    func testBothTimecodeEdgesPersistWithoutLoopingSplittingOrSourceChanges() throws {
        var project = Project.empty(name: "Timecode span")
        let region = Part(id: UUID(), name: "Song", startTime: 30, endTime: 50)
        project.songs[0].parts = [region]
        let clip = AudioClip(id: Project.timecodeItemID(region.id), name: "LTC", startTime: 30, duration: 20, sourceOffset: 4)
        var track = Track(id: UUID(), name: "Timecode", role: TrackRole(rawValue: "timecode"))
        track.clips = [clip]; project.songs[0].tracks = [track]
        let original = project; var history = ProjectEditHistory(project)
        project.resizeItem(clip.id, start: 25, end: 65)
        let resized = project.songs[0].tracks[0].clips[0]
        XCTAssertEqual(resized.timecodeStartOffset, -5); XCTAssertEqual(resized.timecodeEndOffset, 15)
        XCTAssertEqual(resized.sourceOffset, 4); XCTAssertNil(resized.loopStart); XCTAssertNil(resized.loopLength)
        project.splitItems([clip.id], at: 40)
        XCTAssertEqual(project.songs[0].tracks[0].clips, [resized])
        XCTAssertEqual(try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(project)), project)
        history.record(project); XCTAssertEqual(history.undo(), original); XCTAssertEqual(history.redo(), project)
        project.songs[0].tracks[0].clips[0].loopLength = 20
        XCTAssertThrowsError(try project.validate())
    }
    func testTimecodeSpanScalesWithTempoAndRejectsWrongTrackOrNonFiniteOffsets() throws {
        var project = Project.empty(name: "Timecode tempo")
        let region = Part(id: UUID(), name: "Song", startTime: 30, endTime: 50)
        project.songs[0].parts = [region]
        var track = Track(id: UUID(), name: "Timecode", role: TrackRole(rawValue: "timecode"))
        let clip = AudioClip(id: Project.timecodeItemID(region.id), name: "MTC", startTime: 25, duration: 40, timecodeStartOffset: -5, timecodeEndOffset: 15)
        track.clips = [clip]; project.songs[0].tracks = [track]
        project.songs[0].followTempo(240)
        XCTAssertEqual(project.songs[0].tracks[0].clips[0].timecodeStartOffset, -2.5)
        XCTAssertEqual(project.songs[0].tracks[0].clips[0].timecodeEndOffset, 7.5)
        try project.validate()
        project.songs[0].tracks[0].role = .other
        XCTAssertThrowsError(try project.validate())
        project.songs[0].tracks[0].role = TrackRole(rawValue: "timecode")
        project.songs[0].tracks[0].clips[0].timecodeStartOffset = .nan
        XCTAssertThrowsError(try project.validate())
    }
    func testStandardResizeWrapsBackwardAndForwardWithoutChangingOriginalSourceInterval() {
        let original = AudioClip(id: UUID(), name: "Source", startTime: 30, duration: 10, sourceOffset: 3, waveform: [0.1,0.4], gain: 0.5, playbackRate: 2)
        let backward = original.resized(start: 5, end: 70)
        XCTAssertEqual(backward.sourceOffset, 13); XCTAssertEqual(backward.loopStart, 3); XCTAssertEqual(backward.loopLength, 20)
        XCTAssertEqual(backward.waveform, original.waveform); XCTAssertEqual(backward.gain, original.gain)
        let forward = backward.resized(start: 42, end: 120)
        XCTAssertEqual(forward.sourceOffset, 7); XCTAssertEqual(forward.loopStart, 3); XCTAssertEqual(forward.loopLength, 20)
        let restored = forward.resized(start: 30, end: 40)
        XCTAssertEqual(restored.sourceOffset, original.sourceOffset)
        XCTAssertEqual(restored.duration, original.duration)
        XCTAssertEqual(original.resized(start: -1, end: 5), original)
    }
}
