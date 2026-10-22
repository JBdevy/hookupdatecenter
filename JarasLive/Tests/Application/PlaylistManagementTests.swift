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

extension PlaylistManagementTests {
    private func duplicateFixture() throws -> (Project, UUID, UUID, UUID) {
        var project = Project.empty(name: "Duplicate rows")
        let first = Part(id: UUID(), name: "First", startTime: 0, endTime: 60)
        let second = Part(id: UUID(), name: "Second", startTime: 60, endTime: 120)
        project.songs[0].parts = [first, second]
        var list = RegionPlaylist(id: UUID(), name: "Playlist", songId: project.songs[0].id, regionIds: [first.id, second.id])
        let alias = try XCTUnwrap(list.duplicateRegion(first.id))
        var state = RegionSetlist(); state.playlists = [list]; state.selectedId = list.id
        project.regionSetlist = state
        return (project, list.id, first.id, alias)
    }

    func testDuplicateRoundTripPreservesPhysicalArrangementAndSourceEdits() throws {
        var (project, listID, physical, alias) = try duplicateFixture()
        let originalSong = project.songs[0]
        try project.validate()
        let data = try JSONEncoder().encode(project)
        let restored = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(restored.songs, project.songs)
        XCTAssertEqual(restored.regionSetlist, project.regionSetlist)
        var list = try XCTUnwrap(project.regionSetlist?.playlists.first)
        XCTAssertEqual(list.id, listID)
        XCTAssertEqual(list.regionIds, [physical, alias, originalSong.parts[1].id])
        let secondAlias = try XCTUnwrap(list.duplicateRegion(alias))
        XCTAssertEqual(list.regionSourceID(forEntry: secondAlias), physical, "copies of copies point to the physical region")
        XCTAssertEqual(project.songs[0], originalSong)
        project.songs[0].parts[0].name = "Renamed"
        project.songs[0].parts[0].endTime = 55
        let projected = try XCTUnwrap(list.region(forEntry: alias, in: project.songs[0]))
        XCTAssertEqual(projected.id, alias)
        XCTAssertEqual(projected.name, "Renamed")
        XCTAssertEqual(projected.endTime, 55)
        let share = SetlistShareText.make(song: project.songs[0], setlist: project.regionSetlist!, playlistID: listID,
                                         allRegionsTitle: "All", totalDurationTitle: "Total")
        XCTAssertTrue(share.contains("Total: 00:02:50"))
        XCTAssertTrue(share.contains("01. RENAMED\n02. RENAMED\n03. SECOND"))
    }

    func testDuplicateDeletionOnlyRemovesRequestedOccurrenceAndRepairsBlock() throws {
        var (project, listID, physical, alias) = try duplicateFixture()
        let song = project.songs[0]
        project.regionSetlist?.blocks = [SetlistBlock(id: UUID(), songId: song.id, playlistId: listID,
                                                     name: "Next", color: 0, beforeRegionId: alias)]
        project.deleteSetlistEntries([alias], song: song.id, playlist: listID)
        XCTAssertEqual(project.songs[0], song)
        XCTAssertEqual(project.regionSetlist?.playlists[0].regionIds, song.parts.map(\.id))
        XCTAssertNil(project.regionSetlist?.playlists[0].duplicates)
        XCTAssertEqual(project.regionSetlist?.blocks?.first?.beforeRegionId, song.parts[1].id)
        try project.validate()
        var (other, otherList, source, copy) = try duplicateFixture()
        other.deleteSetlistEntries([source], song: other.songs[0].id, playlist: otherList)
        XCTAssertEqual(other.regionSetlist?.playlists[0].regionIds.first, copy)
        XCTAssertNotNil(other.songs[0].parts.first { $0.id == source })
        try other.validate()
        other.deleteRegion(source)
        XCTAssertFalse(other.regionSetlist!.playlists[0].regionIds.contains(copy))
        XCTAssertNil(other.regionSetlist?.playlists[0].duplicates)
        try other.validate()
        XCTAssertNotEqual(physical, alias)
    }

    func testCloningPlaylistRegeneratesAliasIdentityAndBlockAnchors() throws {
        var (project, listID, physical, alias) = try duplicateFixture()
        project.regionSetlist?.blocks = [SetlistBlock(id: UUID(), songId: project.songs[0].id,
                                                     playlistId: listID, name: "Repeat", color: 0, beforeRegionId: alias)]
        let clone = try XCTUnwrap(project.regionSetlist?.clonePlaylist(listID))
        let list = try XCTUnwrap(project.regionSetlist?.playlists.last)
        let newAlias = try XCTUnwrap(list.duplicates?.first?.id)
        XCTAssertEqual(list.id, clone)
        XCTAssertNotEqual(newAlias, alias)
        XCTAssertEqual(list.regionSourceID(forEntry: newAlias), physical)
        XCTAssertEqual(project.regionSetlist?.blocks?.last?.beforeRegionId, newAlias)
        try project.validate()
    }

    func testMalformedDuplicateReferencesAreRejected() throws {
        var (project, _, source, alias) = try duplicateFixture()
        project.regionSetlist?.playlists[0].duplicates?[0].regionId = alias
        XCTAssertThrowsError(try project.validate())
        project.regionSetlist?.playlists[0].duplicates?[0].regionId = source
        project.regionSetlist?.playlists[0].duplicates?[0].id = source
        XCTAssertThrowsError(try project.validate())
    }
}
