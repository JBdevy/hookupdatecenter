import XCTest
@testable import JarasApplication

final class SharedItemBoundaryTests: XCTestCase {
    func testSelectedTextBoundaryExpandsAndContractsWithoutGaps() throws {
        var track = Track(id: UUID(), name: "TP", role: TrackRole(rawValue: "teleprompt"))
        track.clips = (0..<4).map { AudioClip(id: UUID(), name: "Text \($0)", startTime: Double($0 * 10), duration: 10, text: "Line \($0)") }
        let selected = Set(track.clips.map(\.id)), a = track.clips[0].id, b = track.clips[1].id
        for position in [7.0, 13, 25, 39.9] {
            let edit = try XCTUnwrap(TeleprompterBoundaryEdit(track: track, selected: selected, left: a, right: b, position: position))
            XCTAssertEqual(edit.clips[0].startTime, 0)
            XCTAssertEqual(edit.clips[0].duration, position, accuracy: 1e-9)
            XCTAssertEqual(edit.clips.last!.startTime + edit.clips.last!.duration, 40, accuracy: 1e-9)
            for index in 0..<3 {
                XCTAssertEqual(edit.clips[index].startTime + edit.clips[index].duration, edit.clips[index + 1].startTime, accuracy: 1e-9)
                XCTAssertGreaterThanOrEqual(edit.clips[index].duration, 0.01 - 1e-9)
                XCTAssertEqual(edit.clips[index].text, track.clips[index].text)
            }
        }
        let backwards = try XCTUnwrap(TeleprompterBoundaryEdit(track: track, selected: selected,
            left: track.clips[2].id, right: track.clips[3].id, position: 5))
        XCTAssertEqual(backwards.clips[3].startTime, 5, accuracy: 1e-9)
        XCTAssertEqual(backwards.clips[3].duration, 35, accuracy: 1e-9)
        for position in [-100.0, 1000] {
            let edit = try XCTUnwrap(TeleprompterBoundaryEdit(track: track, selected: selected, left: a, right: b, position: position))
            XCTAssertTrue(edit.clips.allSatisfy { $0.duration >= 0.01 })
        }
        XCTAssertNil(TeleprompterBoundaryEdit(track: track, selected: [a], left: a, right: b, position: 12))
        track.role = .other
        XCTAssertNil(TeleprompterBoundaryEdit(track: track, selected: selected, left: a, right: b, position: 12))
    }
    func testRollingTeleprompterTextPreservesOuterEnds() throws {
        var project = Project.empty(name: "Boundary")
        var track = Track(id: UUID(), name: "Teleprompter", role: TrackRole(rawValue: "teleprompt"))
        let left = AudioClip(id: UUID(), name: "Left", startTime: 10, duration: 10, text: "Verse")
        let right = AudioClip(id: UUID(), name: "Right", startTime: 20, duration: 10, text: "Chorus")
        track.clips = [left, right]; project.songs[0].tracks = [track]
        XCTAssertTrue(project.resizeSharedItemBoundary(left: left.id, right: right.id, position: 23))
        let result = project.songs[0].tracks[0].clips
        XCTAssertEqual(result[0].startTime, 10); XCTAssertEqual(result[0].duration, 13)
        XCTAssertEqual(result[1].startTime, 23); XCTAssertEqual(result[1].duration, 7)
        XCTAssertEqual(result[0].text, "Verse"); XCTAssertEqual(result[1].text, "Chorus")
        XCTAssertEqual(left.startTime, 10); XCTAssertEqual(right.startTime, 20)
    }
    func testAdjacentItemsShareBoundaryAcrossTrackKinds() throws {
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
        var track = Track(id: UUID(), name: "Text", role: TrackRole(rawValue: "teleprompt"))
        let a = AudioClip(id: UUID(), name: "A", startTime: 0, duration: 5, text: "Verse")
        var b = AudioClip(id: UUID(), name: "B", startTime: 5, duration: 5, text: "Chorus")
        XCTAssertNotNil(SharedItemBoundaryEdit(song: song, track: track, left: a, right: b, position: 4))
        b.recordingLane = 1; track.clips = [a,b]; song.tracks = [track]
        XCTAssertNil(SharedItemBoundaryEdit(song: song, track: track, left: a, right: b, position: 4))
        b.recordingLane = nil; b.startTime = 5.001
        XCTAssertNil(SharedItemBoundaryEdit(song: song, track: track, left: a, right: b, position: 4))
    }
}
