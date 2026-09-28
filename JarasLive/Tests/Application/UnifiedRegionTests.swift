import XCTest
@testable import JarasApplication

final class UnifiedRegionTests: XCTestCase {
    private func fixture() -> Project {
        var project = Project.empty(name: "Unified")
        let first = Part(id: UUID(), name: "First song (original case)", startTime: 30, endTime: 55, color: 0x123456)
        let second = Part(id: UUID(), name: "Second song", startTime: 50, endTime: 80, color: 0x654321)
        let adjacent = Part(id: UUID(), name: "Separate song", startTime: 80, endTime: 90)
        var track = Track(id: UUID(), name: "Audio", role: .other)
        track.clips = [AudioClip(id: UUID(), name: "One", startTime: 32, duration: 23), AudioClip(id: UUID(), name: "Two", startTime: 50, duration: 30)]
        project.songs[0].duration = 120; project.songs[0].parts = [first, second, adjacent]; project.songs[0].tracks = [track]
        var list = RegionSetlist()
        list.playlists = [RegionPlaylist(id: UUID(), name: "Set", songId: project.songs[0].id, regionIds: [first.id, second.id, adjacent.id])]
        project.regionSetlist = list
        return project
    }
    func testTransportPreviewFollowsDrawerThenReturnsToQueue() throws {
        var project = fixture()
        let first = project.songs[0].parts[0].id, second = project.songs[0].parts[1].id
        let group = try project.unifyRegions(containing: first, name: "Group")
        let song = project.songs[0]
        XCTAssertEqual(song.nextDrawerRegion(group, position: 32)?.id, second)
        XCTAssertEqual(song.nextDrawerRegion(first, position: 49.99)?.id, second)
        XCTAssertNil(song.nextDrawerRegion(group, position: 50), "the final song shows the armed queue from its beginning")
        XCTAssertNil(song.nextDrawerRegion(second, position: 65))
        let regular = song.parts.first { $0.name == "Separate song" }!
        XCTAssertNil(song.nextDrawerRegion(regular.id, position: 85))
        XCTAssertNil(song.nextDrawerRegion(nil, position: 40))
        let untouched = song
        _ = song.nextDrawerRegion(first, position: 40)
        XCTAssertEqual(song, untouched, "display lookup never changes drawer order or playback data")
    }
    func testUnificationPreservesSongsAudioNamesColorsAndPlaylistAndRequiresName() throws {
        var project = fixture(), unchanged = project
        let first = project.songs[0].parts[0], second = project.songs[0].parts[1]
        XCTAssertThrowsError(try project.unifyRegions(containing: first.id, name: "   "))
        XCTAssertEqual(project, unchanged)
        XCTAssertEqual(project.overlappingRegions(containing: second.id).map(\.id), [first.id, second.id])
        let groupID = try project.unifyRegions(containing: first.id, name: "  Special region  ")
        let group = try XCTUnwrap(project.songs[0].parts.first { $0.id == groupID })
        XCTAssertEqual(group.name, "Special region"); XCTAssertEqual(group.startTime, 32); XCTAssertEqual(group.endTime, 80)
        XCTAssertEqual(project.songs[0].parts.filter { $0.parentRegionID == groupID }.map(\.id), [first.id, second.id])
        XCTAssertEqual(project.songs[0].parts.first { $0.id == first.id }?.startTime, 32)
        XCTAssertEqual(project.songs[0].tracks, unchanged.songs[0].tracks)
        XCTAssertEqual(project.songs[0].markers?.map(\.name), [first.name, second.name])
        XCTAssertEqual(project.songs[0].markers?.map(\.position), [30, 50])
        XCTAssertEqual(project.songs[0].markers?.map(\.color), [first.color!, second.color!])
        XCTAssertEqual(project.regionSetlist?.playlists[0].regionIds, [groupID, unchanged.songs[0].parts[2].id])
        XCTAssertEqual(RegionLanes(parts: project.songs[0].parts).count, 1)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project)), project)
        try project.validate()
        unchanged = project
        XCTAssertThrowsError(try project.unifyRegions(containing: first.id, name: "Invalid"))
        XCTAssertEqual(project, unchanged, "songs in a drawer cannot be independently unified")
    }
    func testMergingExistingUnifiedGroupAndDeletingWrapperRestoreSongsWithUndo() throws {
        var project = fixture()
        let oldGroup = try project.unifyRegions(containing: project.songs[0].parts[0].id, name: "First group")
        let next = Part(id: UUID(), name: "Another", startTime: 75, endTime: 85)
        project.songs[0].parts.removeAll { $0.startTime == 80 }
        project.regionSetlist?.playlists[0].regionIds.removeLast()
        project.songs[0].parts.append(next)
        let group = try project.unifyRegions(containing: next.id, name: "")
        XCTAssertEqual(group, oldGroup, "adding a region preserves the special region identity without requiring a name")
        XCTAssertEqual(project.songs[0].parts.first { $0.id == group }?.name, "First group")
        XCTAssertEqual(project.songs[0].parts.filter { $0.parentRegionID == group }.count, 3)
        XCTAssertEqual(project.songs[0].markers?.count, 3)
        XCTAssertTrue(project.songs[0].markers!.allSatisfy { $0.unifiedRegionID == group })
        let before = project; var history = ProjectEditHistory(project)
        project.deleteRegion(group); history.record(project)
        XCTAssertEqual(Set(project.songs[0].parts.map(\.id)), Set(before.songs[0].parts.filter { $0.parentRegionID == group }.map(\.id)))
        XCTAssertTrue(project.songs[0].parts.allSatisfy { $0.parentRegionID == nil })
        XCTAssertEqual(project.regionSetlist?.playlists[0].regionIds.count, 3)
        XCTAssertTrue(project.songs[0].markers!.isEmpty)
        XCTAssertEqual(project.songs[0].tracks, before.songs[0].tracks)
        XCTAssertEqual(history.undo(), before)
        try project.validate()
    }
    func testDisunificationRestoresIndividualRegionsAndPlaylistWithoutRemovingAudio() throws {
        var project = fixture()
        let original = project
        let group = try project.unifyRegions(containing: project.songs[0].parts[0].id, name: "Group")
        let ids = try project.disunifyRegion(group)
        XCTAssertEqual(ids, Array(original.songs[0].parts.prefix(2).map(\.id)))
        XCTAssertEqual(project.songs[0].parts, original.songs[0].parts, "markers restore the original starts, full names and colors")
        XCTAssertEqual(project.regionSetlist, original.regionSetlist)
        XCTAssertEqual(project.songs[0].tracks, original.songs[0].tracks)
        XCTAssertTrue(project.songs[0].markers!.isEmpty)
        let unchanged = project
        XCTAssertThrowsError(try project.disunifyRegion(group))
        XCTAssertEqual(project, unchanged)
        try project.validate()
    }
    func testPlayingHighlightFollowsDrawerSongsButCollapsedHighlightStaysOnGroup() throws {
        var project = fixture()
        let first = project.songs[0].parts[0].id, second = project.songs[0].parts[1].id
        let group = try project.unifyRegions(containing: first, name: "Group")
        let song = project.songs[0]
        XCTAssertEqual(song.playingSetlistRegion(first, position: 40, expanded: [])?.id, group)
        XCTAssertEqual(song.playingSetlistRegion(group, position: 40, expanded: [group])?.id, first)
        XCTAssertEqual(song.playingSetlistRegion(first, position: 52, expanded: [group])?.id, second, "internal marker changes the displayed song, without needing a transport transition")
        XCTAssertEqual(song.playingSetlistRegion(first, position: 65, expanded: [group])?.id, second, "highlight advances after the originally selected child's end")
        XCTAssertEqual(song.playingSetlistRegion(second, position: 65, expanded: [])?.id, group)
        XCTAssertEqual(song.playingSetlistRegion(song.parts.first { $0.name == "Separate song" }!.id, position: 85, expanded: [group])?.name, "Separate song")
        XCTAssertNil(song.playingSetlistRegion(nil, position: 40, expanded: [group]))
    }

    func testEditedUnifiedMarkersRestoreTheirLatestNamesAndColorsOnDisunification() throws {
        var project = fixture()
        let first = project.songs[0].parts[0].id
        let group = try project.unifyRegions(containing: first, name: "Group")
        let marker = try XCTUnwrap(project.songs[0].markers?.firstIndex { $0.sourceRegionID == first })
        project.songs[0].markers![marker].name = "Changed song (Original)"
        project.songs[0].markers![marker].color = 0xff8040
        project = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        try project.disunifyRegion(group)
        let restored = try XCTUnwrap(project.songs[0].parts.first { $0.id == first })
        XCTAssertEqual(restored.name, "Changed song (Original)")
        XCTAssertEqual(restored.color, 0xff8040)
    }

    func testDeletingSpecialRegionFromAllRegionsRestoresEditedSongsAndKeepsManualMarkers() throws {
        var project = fixture()
        let original = project
        let first = project.songs[0].parts[0].id
        let group = try project.unifyRegions(containing: first, name: "Group")
        let index = try XCTUnwrap(project.songs[0].markers?.firstIndex { $0.sourceRegionID == first })
        project.songs[0].markers![index].name = "Edited name (Original)"
        project.songs[0].markers![index].color = 0xff8040
        let manual = TimelineMarker(id: UUID(), name: "Manual", position: 90, color: 0x123456)
        project.songs[0].markers!.append(manual)
        project.deleteSetlistEntries([group], song: project.songs[0].id, playlist: nil)
        XCTAssertEqual(project.songs[0].parts.count, original.songs[0].parts.count)
        XCTAssertEqual(project.songs[0].parts.first { $0.id == first }?.name, "Edited name (Original)")
        XCTAssertEqual(project.songs[0].parts.first { $0.id == first }?.color, 0xff8040)
        XCTAssertEqual(project.regionSetlist?.playlists[0].regionIds, original.regionSetlist?.playlists[0].regionIds)
        XCTAssertEqual(project.songs[0].tracks, original.songs[0].tracks)
        XCTAssertEqual(project.songs[0].markers, [manual])
        try project.validate()
    }

}
