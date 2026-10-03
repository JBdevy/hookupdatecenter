import XCTest
@testable import JarasApplication

final class StemSeparationTests: XCTestCase {
    private func fixture() -> (Project, AudioClip, [Track]) {
        var project = Project.empty(name: "Separation")
        let clip = AudioClip(id: UUID(), name: "Song", startTime: 23, duration: 8, sourceOffset: 4, audioFile: AudioFile(path: "Stems/song.wav"), gain: 0.75, playbackRate: 1.2)
        var original = Track(id: UUID(), name: "Original", role: .other)
        original.clips = [clip]
        project.songs[0].tracks = [original]
        project.songs[0].duration = 60
        let tracks = CatStem.allCases.map { stem -> Track in
            var track = Track(id: UUID(), name: stem.rawValue, role: stem.role, color: stem.color)
            track.clips = [AudioClip(id: UUID(), name: stem.rawValue, startTime: clip.startTime, duration: clip.duration, audioFile: AudioFile(path: "Stems/CatStem-test/\(stem.rawValue).wav"))]
            return track
        }
        return (project, clip, tracks)
    }
    func testSeparationCommitsFiveAlignedTracksAndPreservesOriginalWithSingleUndo() throws {
        var (project, clip, tracks) = fixture()
        let original = project
        var history = ProjectEditHistory(project)
        try project.insertSeparatedStems(tracks, song: project.songs[0].id, sourceTrack: project.songs[0].tracks[0].id, original: clip)
        history.record(project)
        XCTAssertEqual(project.songs[0].tracks.count, 6)
        let source = project.songs[0].tracks[0].clips[0]
        XCTAssertEqual(source.muted, true)
        XCTAssertEqual(source.separatedStemTracks, tracks.map(\.id))
        XCTAssertEqual(source.audioFile, clip.audioFile)
        XCTAssertEqual(source.sourceOffset, clip.sourceOffset)
        XCTAssertEqual(source.playbackRate, clip.playbackRate)
        XCTAssertEqual(source.gain, clip.gain)
        XCTAssertEqual(tracks.map(\.name), ["Vocal", "Drum", "Bass", "Guitar", "Other"])
        XCTAssertTrue(tracks.allSatisfy { $0.clips[0].startTime == 23 && $0.clips[0].duration == 8 })
        XCTAssertEqual(history.undo(), original)
        XCTAssertEqual(history.redo(), project)
        let restored = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(restored, project)
    }
    func testChangedSourceAndIncompleteResultsCannotPartiallyModifyProject() throws {
        var (project, clip, tracks) = fixture()
        project.songs[0].tracks[0].clips[0].startTime += 1
        let before = project
        XCTAssertThrowsError(try project.insertSeparatedStems(tracks, song: project.songs[0].id, sourceTrack: project.songs[0].tracks[0].id, original: clip))
        XCTAssertEqual(before, project)
        project.songs[0].tracks[0].clips[0] = clip
        let unchanged = project
        XCTAssertThrowsError(try project.insertSeparatedStems(Array(tracks.prefix(4)), song: project.songs[0].id, sourceTrack: project.songs[0].tracks[0].id, original: clip))
        XCTAssertEqual(project, unchanged)
    }
    func testDuplicateOutputIDsAreRejectedAndNoSourceIsMuted() throws {
        var (project, clip, tracks) = fixture()
        tracks[1].id = tracks[0].id
        let original = project
        XCTAssertThrowsError(try project.insertSeparatedStems(tracks, song: project.songs[0].id, sourceTrack: project.songs[0].tracks[0].id, original: clip))
        XCTAssertEqual(project, original)
    }
}
