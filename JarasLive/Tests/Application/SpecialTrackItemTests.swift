import XCTest
@testable import JarasApplication

final class SpecialTrackItemTests: XCTestCase {
    private func track(_ kind: TrackKind) -> Track {
        var track = Track(id: UUID(), name: kind.title, role: TrackRole(rawValue: kind.rawValue))
        track.clips = [AudioClip(id: UUID(), name: "First", startTime: 10, duration: 10),
                       AudioClip(id: UUID(), name: "Second", startTime: 30, duration: 10)]
        return track
    }
    func testSpecialTracksHaveOneLaneAndAcceptAdjacentItems() throws {
        for kind: TrackKind in [.teleprompt, .video, .chords] {
            var project = Project.empty(name: "Single lane")
            project.songs[0].duration = 100
            var lane = track(kind)
            project.songs[0].tracks = [lane]
            try project.validate()
            XCTAssertFalse(lane.canPlaceItem(start: 15, duration: 10))
            XCTAssertTrue(lane.canPlaceItem(start: 20, duration: 10))
            lane.clips[1].startTime = 19
            project.songs[0].tracks = [lane]
            XCTAssertThrowsError(try project.validate())
            lane.clips[1].startTime = 20
            project.songs[0].tracks = [lane]
            try project.validate()
            XCTAssertEqual(TrackLanes(track: lane).count, 1)
        }
    }
    func testSpecialResizeAndDragPreviewCannotStackItems() throws {
        for kind: TrackKind in [.teleprompt, .video, .chords] {
            var project = Project.empty(name: "Single lane")
            project.songs[0].duration = 100
            let lane = track(kind), first = lane.clips[0], second = lane.clips[1]
            project.songs[0].tracks = [lane]
            let original = project
            project.resizeItem(first.id, start: 10, end: 35)
            XCTAssertEqual(project, original)
            let start = lane.constrainedItemStart(15, item: second)
            XCTAssertTrue(lane.canPlaceItem(start: start, duration: second.duration, excluding: second.id))
            let (left, right) = lane.constrainedItemEdges(start: 0, end: 100, item: second)
            XCTAssertEqual(left, 20); XCTAssertEqual(right, 100)
            if kind.isText {
                project.resizeItem(first.id, start: 10, end: 30)
                XCTAssertEqual(project.songs[0].tracks[0].clips[0].duration, 20)
                try project.validate()
            }
        }
        var ordinary = track(.standard)
        ordinary.name = "Audio"
        XCTAssertTrue(ordinary.canPlaceItem(start: 15, duration: 10))
    }
}
