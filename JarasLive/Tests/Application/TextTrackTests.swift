import XCTest
@testable import JarasApplication

final class TextTrackTests: XCTestCase {
    func testTeleprompterMediaCanOverlapTextButNotOtherMediaAndStaysOnItsTrack() throws {
        var project = fixture()
        let textID = project.songs[0].tracks[2].clips[0].id
        let media = AudioClip(id: UUID(), name: "Movie", startTime: 0, duration: 20, audioFile: AudioFile(path: "Videos/movie.mov"))
        project.songs[0].tracks[2].clips.append(media)
        try project.validate()
        XCTAssertEqual(TrackLanes(track: project.songs[0].tracks[2]).count, 2)
        XCTAssertTrue(project.songs[0].tracks[2].canPlaceItem(start: 15, duration: 10), "adding text ignores the media layer")
        XCTAssertFalse(project.songs[0].tracks[2].canPlaceItem(start: 5, duration: 10), "text still cannot overlap text")
        XCTAssertEqual(project.songs[0].tracks[2].constrainedItemStart(5, item: media), 5)
        let data = try ProjectDocumentCodec.encode(project)
        XCTAssertEqual(try ProjectDocumentCodec.decode(data), project)
        var collision = media; collision.id = UUID(); collision.startTime = 5
        project.songs[0].tracks[2].clips.append(collision)
        XCTAssertThrowsError(try project.validate())
        project.songs[0].tracks[2].clips.removeLast()
        project.songs[0].tracks[2].clips[0].audioFile = AudioFile(path: "Steams/audio.wav")
        XCTAssertEqual(project.songs[0].tracks[2].clips[0].id, textID)
        XCTAssertThrowsError(try project.validate(), "teleprompter does not accept audio stems")
    }
    private func fixture() -> Project {
        var project = Project.empty(name: "Lyrics and chords")
        project.songs[0].duration = 40
        var chords = Track(id: UUID(), name: "Chords", role: .chords)
        chords.clips = [AudioClip(id: UUID(), name: "Chords", startTime: 5, duration: 10, text: "C♯m / G♭\nRefrão 🎵")]
        var lyrics = Track(id: UUID(), name: "Teleprompter", role: .init(rawValue: "teleprompt"))
        lyrics.clips = [AudioClip(id: UUID(), name: "Teleprompter", startTime: 0, duration: 10, text: "Canção de amanhã 🎤")]
        project.songs[0].tracks = [Track(id: UUID(), name: "Piano", role: .keys), chords, lyrics]
        return project
    }
    func testChordsOrderingAndEncryptedTextPersistenceAllowMultipleTracks() throws {
        var project = fixture()
        let second = Track(id: UUID(), name: "Chords", role: .chords)
        project.songs[0].tracks.insert(second, at: 0)
        project.orderSpecialTracks()
        XCTAssertEqual(project.songs[0].tracks.map(\.kind), [.chords, .chords, .teleprompt, .standard])
        XCTAssertEqual(project.songs[0].tracks.filter { $0.kind == .chords }.map(\.id), [second.id, fixtureChordsID(project)])
        XCTAssertEqual(TrackRole.chords.rawValue, "chords")
        XCTAssertEqual(TrackKind.chords.title, "Chords")
        XCTAssertTrue(TrackKind.chords.isText)
        try project.validate()
        XCTAssertEqual(try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(project)), project)
        var withoutText = project
        for track in withoutText.songs[0].tracks.indices {
            for item in withoutText.songs[0].tracks[track].clips.indices { withoutText.songs[0].tracks[track].clips[item].text = nil }
        }
        let data = try JSONEncoder().encode(withoutText)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"text\""))
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: data), withoutText)
    }
    private func fixtureChordsID(_ project: Project) -> UUID { project.songs[0].tracks.first { $0.kind == .chords && !$0.clips.isEmpty }!.id }
    func testTextMaximumCountsUnicodeRatherThanBytesAndRejectsAudioMetadata() throws {
        var project = fixture()
        for text in [String(repeating: "é", count: 30), String(repeating: "🎵", count: 30)] {
            project.songs[0].tracks[1].clips[0].text = text
            try project.validate()
            XCTAssertEqual(try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(project)), project)
            project.songs[0].tracks[1].clips[0].text = text + "A"
            XCTAssertThrowsError(try project.validate())
        }
        project = fixture()
        project.songs[0].tracks[0].clips = project.songs[0].tracks[1].clips
        project.songs[0].tracks[1].clips = []
        XCTAssertThrowsError(try project.validate(), "text cannot be assigned to an audio track")
        project = fixture()
        project.songs[0].tracks[1].clips[0].audioFile = AudioFile(path: "Steams/invalid.wav")
        XCTAssertThrowsError(try project.validate())
        project = fixture()
        project.songs[0].tracks[1].fx = NativeFXSettings()
        XCTAssertThrowsError(try project.validate())
    }
    func testTextResizeSplitAndUndoNeverCreateSourceLoops() throws {
        var project = fixture()
        let original = project
        let clip = project.songs[0].tracks[1].clips[0]
        var history = ProjectEditHistory(project)
        project.resizeItem(clip.id, start: 2, end: 30)
        let resized = project.songs[0].tracks[1].clips[0]
        XCTAssertEqual(resized.startTime, 2); XCTAssertEqual(resized.duration, 28)
        XCTAssertEqual(resized.text, clip.text)
        XCTAssertEqual(resized.sourceOffset, 0)
        XCTAssertNil(resized.loopStart); XCTAssertNil(resized.loopLength)
        project.splitItems([clip.id], at: 15)
        XCTAssertEqual(project.songs[0].tracks[1].clips.map(\.text), [clip.text, clip.text])
        XCTAssertTrue(project.songs[0].tracks[1].clips.allSatisfy { $0.sourceOffset == 0 && $0.loopStart == nil && $0.loopLength == nil })
        try project.validate()
        history.record(project)
        XCTAssertEqual(history.undo(), original)
        XCTAssertEqual(history.redo(), project)
    }
}
