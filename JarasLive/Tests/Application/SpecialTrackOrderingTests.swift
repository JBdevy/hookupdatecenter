import XCTest
@testable import JarasApplication

final class SpecialTrackOrderingTests: XCTestCase {
    func testGlobalTrackCapacityAcceptsFourHundredAndRejectsFourHundredOne() throws {
        var project = Project.empty(name: "Capacity")
        project.songs[0].tracks = (0..<400).map { Track(id: UUID(), name: "Track \($0)", role: .other) }
        try project.validate()
        project.songs[0].tracks.append(Track(id: UUID(), name: "Extra", role: .other))
        XCTAssertThrowsError(try project.validate())
        project.songs[0].tracks.removeLast()
        var secondSong = project.songs[0]
        secondSong.id = UUID(); secondSong.tracks = [Track(id: UUID(), name: "Extra", role: .other)]
        project.songs.append(secondSong)
        XCTAssertThrowsError(try project.validate(), "capacity applies across the entire project")
    }
    private func fixture() -> Project {
        var project = Project.empty(name: "Track order")
        project.songs[0].duration = 120
        let folder = Track(id: UUID(), name: "Keys", role: .keys)
        var child = Track(id: UUID(), name: "Piano", role: .keys)
        child.parentTrackID = folder.id; child.patch = .masterGroup
        child.clips = [AudioClip(id: UUID(), name: "Piano", startTime: 30, duration: 20, waveform: [0.1,0.4], gain: 0.6)]
        var timecode = Track(id: UUID(), name: "Timecode", role: TrackRole(rawValue: "timecode"))
        timecode.clips = [AudioClip(id: UUID(), name: "LTC", startTime: 30, duration: 20)]
        let video1 = Track(id: UUID(), name: "Video", role: TrackRole(rawValue: "video"))
        let video2 = Track(id: UUID(), name: "Video", role: TrackRole(rawValue: "video"))
        let teleprompter = Track(id: UUID(), name: "Teleprompter", role: TrackRole(rawValue: "teleprompt"))
        let bass = Track(id: UUID(), name: "Bass", role: .bass)
        let chords = Track(id: UUID(), name: "Chords", role: .chords)
        project.songs[0].tracks = [folder, video1, child, timecode, bass, teleprompter, video2, chords]
        return project
    }
    func testNormalizeOlderOrderKeepsGroupsClipDataAndDuplicateSpecialOrder() throws {
        var project = fixture()
        let initial = project.songs[0].tracks
        project.orderSpecialTracks()
        XCTAssertEqual(project.songs[0].tracks.map(\.name), ["Timecode", "Chords", "Teleprompter", "Video", "Video", "Keys", "Piano", "Bass"])
        XCTAssertEqual(project.songs[0].tracks.filter { $0.kind == .video }, initial.filter { $0.kind == .video })
        XCTAssertEqual(project.songs[0].tracks.filter { $0.kind == .standard }, initial.filter { $0.kind == .standard })
        XCTAssertEqual(project.songs[0].tracks.first { $0.kind == .timecode }, initial.first { $0.kind == .timecode })
        try project.validate()
        let normalized = project
        project.orderSpecialTracks()
        XCTAssertEqual(project, normalized)
    }
    func testDeletingSpecialTrackSkipsItsPrefixSlotAndUndoRestoresOrder() throws {
        var project = fixture(); project.orderSpecialTracks()
        let original = project
        let teleprompter = try XCTUnwrap(project.songs[0].tracks.first { $0.kind == .teleprompt })
        var history = ProjectEditHistory(project)
        project.deleteTracks([teleprompter.id]); history.record(project)
        XCTAssertEqual(project.songs[0].tracks.map(\.name), ["Timecode", "Chords", "Video", "Video", "Keys", "Piano", "Bass"])
        XCTAssertEqual(history.undo(), original)
        XCTAssertEqual(history.redo(), project)
        project.ungroupTrack(project.songs[0].tracks.first { $0.name == "Keys" }!.id)
        XCTAssertNil(project.songs[0].tracks.first { $0.name == "Piano" }?.parentTrackID)
        XCTAssertEqual(project.songs[0].tracks.first { $0.name == "Piano" }?.primaryOutput, .master)
        XCTAssertEqual(project.songs[0].tracks.prefix(4).map(\.kind), [.timecode,.chords,.video,.video])
        try project.validate()
    }
}
