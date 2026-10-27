import XCTest
@testable import JarasApplication

final class PlaybackScopeTests: XCTestCase {
    func testAutomaticSubplayUsesItemOwnerAndKeepsIncomingTrackAudibleAfterPromotion() {
        let song = Project.empty(name: "Subplay ownership").songs[0]
        let old = UUID(), incoming = UUID(), selected = UUID(), other = UUID()
        var transport = TransportState(playing: true, songId: song.id, position: 9,
            queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: true, position: 20))
        transport.subExclusivePlaybackRegionId = incoming
        XCTAssertFalse(song.allowsExclusiveSubplay(transport, head: 0, track: selected, owner: old, selectedTracks: [selected]))
        XCTAssertFalse(song.allowsExclusiveSubplay(transport, head: 1, track: selected, owner: old, selectedTracks: [selected]))
        XCTAssertTrue(song.allowsExclusiveSubplay(transport, head: 1, track: selected, owner: incoming, selectedTracks: [selected]))
        XCTAssertTrue(song.allowsExclusiveSubplay(transport, head: 0, track: other, owner: old, selectedTracks: [selected]))
        transport.exclusivePlaybackRegionId = incoming; transport.subExclusivePlaybackRegionId = nil
        transport.subPlay.playing = false
        XCTAssertTrue(song.allowsExclusiveSubplay(transport, head: 0, track: selected, owner: incoming, selectedTracks: [selected]))
        XCTAssertFalse(song.allowsExclusiveSubplay(transport, head: 0, track: selected, owner: old, selectedTracks: [selected]))
        XCTAssertTrue(song.allowsExclusiveSubplay(transport, head: 0, track: selected, owner: nil, selectedTracks: [selected]))
    }

    func testCompiledItemStartIndexMatchesLiveOwnershipLookup() {
        var song = Project.empty(name: "Playback index").songs[0]
        let group = UUID(), a = UUID(), b = UUID()
        song.parts = [Part(id: group, name: "Unified", startTime: 0, endTime: 30),
                      Part(id: a, name: "A", startTime: 0, endTime: 16),
                      Part(id: b, name: "B", startTime: 10, endTime: 30)]
        song.parts[1].parentRegionID = group; song.parts[2].parentRegionID = group
        for initialized in [false, true] {
            song.regionOwnershipInitialized = initialized
            for flag in [8.0, 10, 12] {
                song.markers = [TimelineMarker(id: UUID(), name: "B", position: flag, color: 0,
                                              unifiedRegionID: group, sourceRegionID: b)]
                let index = PlaybackItemStartIndex(song: song)
                for owner in [nil, a, b, group, UUID()] {
                    for position in stride(from: 0.0, through: 35, by: 0.25) {
                        let clip = AudioClip(id: UUID(), name: "Item", startTime: position, duration: 4, regionOwnerID: owner)
                        XCTAssertEqual(index.start(for: clip), song.playbackItemStart(clip))
                    }
                }
            }
        }
    }
    func testOverlappingUnifiedSongsAssignNewOnsetsToIncomingSong() {
        var song = Project.empty(name: "Escudo overlap").songs[0]
        let group = UUID(), a = UUID(), b = UUID()
        let start = 51915.98192699533
        song.parts = [
            Part(id: group, name: "H", startTime: 51829.96116741481, endTime: 52194.98192699533),
            Part(id: a, name: "Abertura", startTime: 51829.96116741481, endTime: 51920.46116741484, parentRegionID: group),
            Part(id: b, name: "Escudo", startTime: start, endTime: 52194.98192699533, parentRegionID: group)]
        XCTAssertEqual(song.regionOwner(at: start), b)
        XCTAssertEqual(song.regionOwner(at: start - 0.0000004), b)
        XCTAssertEqual(song.regionOwner(at: start + 0.676358073), b)
        XCTAssertEqual(song.regionOwner(at: start - 1), a)
        song.parts.reverse()
        XCTAssertEqual(song.regionOwner(at: start), b, "Independent of region creation order")
    }

    func testEarlierUnifiedFlagIncludesNewlyExposedItemsButKeepsPreviousTailsExcluded() {
        var song = Project.empty(name: "Moved boundary").songs[0]
        let group = UUID(), a = UUID(), b = UUID()
        song.parts = [Part(id: group, name: "Group", startTime: 0, endTime: 40),
            Part(id: a, name: "A", startTime: 0, endTime: 22),
            Part(id: b, name: "B", startTime: 20, endTime: 40)]
        song.parts[1].parentRegionID = group; song.parts[2].parentRegionID = group
        song.markers = [TimelineMarker(id: UUID(), name: "B", position: 17.5, color: 0,
            unifiedRegionID: group, sourceRegionID: b)]
        song.regionOwnershipInitialized = true
        var transport = TransportState(playing: true, songId: song.id, position: 19,
            regionId: group, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0))
        transport.playbackStartRegionId = song.playbackEntryRegion(at: 19)
        XCTAssertEqual(transport.playbackStartRegionId, b)
        let scope = song.playbackScope(transport)
        XCTAssertEqual(scope.minimum, 17.5)
        let pickup = AudioClip(id: UUID(), name: "B regency pickup", startTime: 18.2, duration: 1, regionOwnerID: a)
        let click = AudioClip(id: UUID(), name: "B click", startTime: 17.5, duration: 15, regionOwnerID: a)
        let tail = AudioClip(id: UUID(), name: "A tail", startTime: 0, duration: 22, regionOwnerID: a)
        let moved = AudioClip(id: UUID(), name: "Deliberately moved A", startTime: 24, duration: 1, regionOwnerID: a)
        XCTAssertTrue(scope.allows(song.playbackItemStart(pickup)))
        XCTAssertTrue(scope.allows(song.playbackItemStart(click)))
        XCTAssertFalse(scope.allows(song.playbackItemStart(tail)))
        XCTAssertFalse(scope.allows(song.playbackItemStart(moved)))
    }

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
