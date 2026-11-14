import XCTest
@testable import JarasApplication

final class SharedItemBoundaryTests: XCTestCase {
    func testRollingEditPreservesOuterEndsAndSourceRate() throws {
        var project = Project.empty(name: "Boundary")
        var track = Track(id: UUID(), name: "Audio", role: .other)
        var left = AudioClip(id: UUID(), name: "Left", startTime: 10, duration: 10, audioFile: AudioFile(path: "a.wav"))
        var right = AudioClip(id: UUID(), name: "Right", startTime: 20, duration: 10, audioFile: AudioFile(path: "b.wav"))
        left.playbackRate = 1.5; right.playbackRate = 2; right.sourceOffset = 4
        track.clips = [left, right]; project.songs[0].tracks = [track]
        XCTAssertTrue(project.resizeSharedItemBoundary(left: left.id, right: right.id, position: 23, sourceDurations: [left.id: 60, right.id: 60]))
        let result = project.songs[0].tracks[0].clips
        XCTAssertEqual(result[0].startTime, 10); XCTAssertEqual(result[0].duration, 13)
        XCTAssertEqual(result[1].startTime, 23); XCTAssertEqual(result[1].duration, 7)
        XCTAssertEqual(result[1].sourceOffset, 10); XCTAssertEqual(result[1].playbackRate, 2)
        XCTAssertEqual(left.startTime, 10); XCTAssertEqual(right.startTime, 20)
    }
    func testAllTextMIDIAndTimecodeItemsAndAtomicRejection() throws {
        for role in ["other", "teleprompt", "teleprompt2", "chords", "timecode", "video"] {
            var project = Project.empty(name: "Boundary")
            var track = Track(id: UUID(), name: role, role: TrackRole(rawValue: role))
            track.importedTimecodeItems = true
            var a = AudioClip(id: UUID(), name: "A", startTime: 0, duration: 5, text: "Verse")
            var b = AudioClip(id: UUID(), name: "B", startTime: 5, duration: 5, text: "Chorus")
            if role == "video" { a.audioFile = AudioFile(path: "a.mp4"); b.audioFile = AudioFile(path: "b.mp4") }
            if role == "other" { a.midi = MIDIItem(); b.midi = MIDIItem() }
            track.clips = [a,b]; project.songs[0].tracks = [track]
            XCTAssertTrue(project.resizeSharedItemBoundary(left: a.id, right: b.id, position: 3, sourceDurations: [a.id: 10,b.id: 10]), role)
            XCTAssertEqual(project.songs[0].tracks[0].clips[0].duration, 3, role)
            XCTAssertEqual(project.songs[0].tracks[0].clips[1].duration, 7, role)
            let saved = project
            XCTAssertFalse(project.resizeSharedItemBoundary(left: b.id, right: a.id, position: 4))
            XCTAssertEqual(project, saved, "Invalid pairs must not partially edit the document")
        }
    }
    func testMinimumDurationSurvivesFloatingPointTimelineSubtraction() throws {
        let song = Project.empty(name: "Boundary").songs[0]
        let track = Track(id: UUID(), name: "Text", role: TrackRole(rawValue: "teleprompt"))
        let a = AudioClip(id: UUID(), name: "A", startTime: 5, duration: 5, text: "A")
        let b = AudioClip(id: UUID(), name: "B", startTime: 10, duration: 8, text: "B")
        let edit = try XCTUnwrap(SharedItemBoundaryEdit(song: song, track: track, left: a, right: b, position: 4))
        XCTAssertGreaterThanOrEqual(edit.left.duration, 0.01)
        XCTAssertEqual(edit.left.startTime + edit.left.duration, edit.right.startTime, accuracy: 1e-9)
        XCTAssertEqual(edit.right.startTime + edit.right.duration, 18, accuracy: 1e-9)
    }
    func testSeparateLanesAndGapsNeverFormSharedBoundary() {
        var song = Project.empty(name: "Boundary").songs[0]
        var track = Track(id: UUID(), name: "Audio", role: .other)
        let a = AudioClip(id: UUID(), name: "A", startTime: 0, duration: 5)
        var b = AudioClip(id: UUID(), name: "B", startTime: 5, duration: 5)
        b.recordingLane = 1; track.clips = [a,b]; song.tracks = [track]
        XCTAssertNil(SharedItemBoundaryEdit(song: song, track: track, left: a, right: b, position: 4))
        b.recordingLane = nil; b.startTime = 5.001
        XCTAssertNil(SharedItemBoundaryEdit(song: song, track: track, left: a, right: b, position: 4))
    }
}
