import XCTest
@testable import JarasApplication
final class PlaylistManagementTests: XCTestCase {
    func testCloneKeepsOrderAndIndependentBlocks() throws {
        let song = UUID(), first = UUID(), second = UUID(), original = UUID()
        var state = RegionSetlist()
        state.playlists = [RegionPlaylist(id: original,name: "Set",songId: song,regionIds: [second,first])]
        state.selectedId = original
        state.blocks = [SetlistBlock(id: UUID(),songId: song,playlistId: original,name: "Intro",color: 0xff0000,beforeRegionId: second,symbol: false)]
        let copy = try XCTUnwrap(state.clonePlaylist(original))
        XCTAssertEqual(state.playlists.last?.name, "Set-2")
        XCTAssertEqual(state.playlists.last?.regionIds, [second,first])
        XCTAssertEqual(state.selectedId, original)
        XCTAssertEqual(state.blocks?.last?.playlistId, copy)
        XCTAssertNotEqual(state.blocks?.first?.id, state.blocks?.last?.id)
        XCTAssertEqual(state.blocks?.last?.symbol, false)
        XCTAssertEqual(state.blocks?.last?.beforeRegionId, second)
        _ = state.clonePlaylist(copy)
        XCTAssertEqual(state.playlists.last?.name, "Set-3")
        _ = state.clonePlaylist(original)
        XCTAssertEqual(state.playlists.last?.name, "Set-4")
        XCTAssertTrue(state.deletePlaylist(copy))
        XCTAssertEqual(state.selectedId, original)
        XCTAssertFalse(state.blocks!.contains { $0.playlistId == copy })
        XCTAssertTrue(state.deletePlaylist(original))
        XCTAssertNil(state.selectedId)
        XCTAssertEqual(state.playlists.count, 2)
        XCTAssertEqual(state.playlists.first?.regionIds, [second,first])
        XCTAssertNil(state.clonePlaylist(UUID()))
        XCTAssertFalse(state.deletePlaylist(UUID()))
    }
}
