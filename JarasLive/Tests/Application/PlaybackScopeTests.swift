import XCTest
@testable import JarasApplication

final class PlaybackScopeTests: XCTestCase {
    func testEntryAndMembershipAreIndependentOfPlayheadAndRoundedOnset() {
        var song = Project.empty(name: "Playback scope").songs[0]
        let group = UUID(), a = UUID(), b = UUID()
        song.parts = [Part(id: group, name: "Group", startTime: 0, endTime: 30),
            Part(id: a, name: "A", startTime: 0, endTime: 25, parentRegionID: group),
            Part(id: b, name: "B", startTime: 20, endTime: 30, parentRegionID: group)]
        song.regionOwnershipInitialized = true
        let tail = AudioClip(id: UUID(), name: "A", startTime: 0, duration: 25, regionOwnerID: a)
        let incoming = AudioClip(id: UUID(), name: "B", startTime: 20 - 0.0000004, duration: 10, regionOwnerID: b)
        var transport = TransportState(playing: true, songId: song.id, position: 24,
            regionId: group, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0))
        transport.playbackStartRegionId = song.playbackEntryRegion(at: 24)
        XCTAssertEqual(transport.playbackStartRegionId, b)
        XCTAssertFalse(song.playbackScope(transport).allows(song.playbackItemStart(tail)))
        XCTAssertTrue(song.playbackScope(transport).allows(song.playbackItemStart(incoming)))
        transport.playbackStartRegionId = a
        XCTAssertTrue(song.playbackScope(transport).allows(song.playbackItemStart(tail)))
        transport.ignoreNextAfter = 20
        XCTAssertTrue(song.playbackScope(transport).allows(song.playbackItemStart(tail)))
        XCTAssertFalse(song.playbackScope(transport).allows(song.playbackItemStart(incoming)))
        transport.subPlaybackStartRegionId = b
        XCTAssertTrue(song.playbackScope(transport, head: 1).allows(song.playbackItemStart(incoming)))
        XCTAssertFalse(song.playbackScope(transport, head: 1).allows(song.playbackItemStart(tail)))
        var moved = tail; moved.startTime = 22
        XCTAssertFalse(song.playbackScope(transport, head: 1).allows(song.playbackItemStart(moved)))
        moved.regionOwnerID = nil
        XCTAssertTrue(song.playbackScope(transport, head: 1).allows(song.playbackItemStart(moved)))
    }
}
