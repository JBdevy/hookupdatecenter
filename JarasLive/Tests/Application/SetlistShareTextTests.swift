import XCTest
@testable import JarasApplication

final class SetlistShareTextTests: XCTestCase {
    private func song(_ parts: [Part]) -> Song {
        var song = Project.empty(name: "Share").songs[0]
        song.parts = parts
        return song
    }

    private func text(_ song: Song, _ setlist: RegionSetlist = RegionSetlist(), playlist: UUID? = nil) -> String {
        SetlistShareText.make(song: song, setlist: setlist, playlistID: playlist,
                             allRegionsTitle: "All regions", totalDurationTitle: "Total duration")
    }

    func testExplicitUnselectedPlaylistPreservesPlaylistOrderAndSelection() {
        let first = Part(id: UUID(), name: "First", startTime: 0, endTime: 60)
        let second = Part(id: UUID(), name: "Second", startTime: 100, endTime: 220, uppercaseName: false)
        let child = Part(id: UUID(), name: "Inside", startTime: 10, endTime: 20, parentRegionID: first.id)
        let song = song([first, second, child])
        let selected = RegionPlaylist(id: UUID(), name: "Selected", songId: song.id, regionIds: [first.id])
        let requested = RegionPlaylist(id: UUID(), name: "Saturday show", songId: song.id,
                                       regionIds: [second.id, UUID(), child.id])
        var state = RegionSetlist()
        state.playlists = [selected, requested]
        state.selectedId = selected.id
        let original = state

        XCTAssertEqual(text(song, state, playlist: requested.id), """
        Saturday show
        Total duration: 00:02:00

        01. Second
        """)
        XCTAssertEqual(state, original, "Copying another playlist must preserve the active playlist")

        state.playlists[1].regionIds = [second.id, first.id]
        XCTAssertEqual(text(song, state, playlist: requested.id), """
        Saturday show
        Total duration: 00:03:00

        01. Second
        02. FIRST
            └─ INSIDE
        """)
    }

    func testAllRegionsUsesTimelineOrderAndUUIDTiesRegardlessOfSelectedPlaylist() {
        let first = Part(id: UUID(), name: "First", startTime: 0, endTime: 60)
        let tiedFirst = Part(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                             name: "Longer", startTime: 60, endTime: 80)
        let tiedLast = Part(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                            name: "Shorter", startTime: 60, endTime: 75)
        let orphan = Part(id: UUID(), name: "Orphan", startTime: 0, endTime: 500, parentRegionID: UUID())
        let song = song([tiedLast, orphan, tiedFirst, first])
        let playlist = RegionPlaylist(id: UUID(), name: "Selected", songId: song.id, regionIds: [tiedLast.id])
        var state = RegionSetlist()
        state.playlists = [playlist]
        state.selectedId = playlist.id

        XCTAssertEqual(text(song, state), """
        All regions
        Total duration: 00:01:35

        01. FIRST
        02. LONGER
        03. SHORTER
        """)
    }

    func testUnifiedDrawerIncludesEveryChildInTimelineOrderAndCountsOnlyRootSpans() {
        let group = Part(id: UUID(), name: "Medley (live)", startTime: 0, endTime: 3661.9)
        let late = Part(id: UUID(), name: "Last Song", startTime: 120, endTime: 3661.9, uppercaseName: false, parentRegionID: group.id)
        let longer = Part(id: UUID(), name: "Longer Song", startTime: 10, endTime: 120, parentRegionID: group.id)
        let shorter = Part(id: UUID(), name: "Shorter Song", startTime: 10, endTime: 60, parentRegionID: group.id)
        let end = Part(id: UUID(), name: "Ending", startTime: 3700, endTime: 3701.9)

        XCTAssertEqual(text(song([late, longer, group, end, shorter])), """
        All regions
        Total duration: 01:01:03

        01. MEDLEY (live)
            ├─ SHORTER SONG
            ├─ LONGER SONG
            └─ Last Song
        02. ENDING
        """, "Collapsed drawer contents are always included; fractional root durations are summed before truncation")
    }

    func testNamedBlocksFollowPlaylistAnchorsAndTrailingOrderWithoutChangingNumbering() {
        let first = Part(id: UUID(), name: "First", startTime: 0, endTime: 10)
        let second = Part(id: UUID(), name: "Second", startTime: 20, endTime: 40)
        let song = song([first, second])
        let playlist = RegionPlaylist(id: UUID(), name: "Show", songId: song.id, regionIds: [second.id, first.id])
        func block(_ name: String, before id: UUID?) -> SetlistBlock {
            SetlistBlock(id: UUID(), songId: song.id, playlistId: playlist.id, name: name, color: 0, beforeRegionId: id)
        }
        var state = RegionSetlist()
        state.playlists = [playlist]
        var otherSong = block("Other song", before: second.id)
        otherSong.songId = UUID()
        var otherPlaylist = block("Other playlist", before: second.id)
        otherPlaylist.playlistId = nil
        state.blocks = [block("Encore", before: first.id), block("Closing notes", before: nil),
                        block("Opening set", before: second.id), block("Opening notes", before: second.id),
                        block(" ", before: first.id), block("Stale anchor", before: UUID()), otherSong, otherPlaylist]

        XCTAssertEqual(text(song, state, playlist: playlist.id), """
        Show
        Total duration: 00:00:30

        Opening set

        Opening notes
        01. SECOND

        Encore
        02. FIRST

        Closing notes
        """)
    }

    func testAllRegionsIncludesOnlyItsOwnBlocksAndLocalizedLabels() {
        let first = Part(id: UUID(), name: "Canção", startTime: 0, endTime: 60)
        let song = song([first])
        var state = RegionSetlist()
        state.blocks = [SetlistBlock(id: UUID(), songId: song.id, playlistId: nil, name: "Abertura", color: 0, beforeRegionId: first.id),
                        SetlistBlock(id: UUID(), songId: song.id, playlistId: UUID(), name: "Hidden", color: 0, beforeRegionId: first.id)]

        XCTAssertEqual(SetlistShareText.make(song: song, setlist: state, playlistID: nil,
                                            allRegionsTitle: "Todas as regiões", totalDurationTitle: "Duração total"), """
        Todas as regiões
        Duração total: 00:01:00

        Abertura
        01. CANÇÃO
        """)
    }

    func testEmptyAndStaleRegionListsKeepTheirOwnHeaderAndZeroTotal() {
        let emptySong = song([])
        XCTAssertEqual(text(emptySong), "All regions\nTotal duration: 00:00:00")
        let populatedSong = song([Part(id: UUID(), name: "Outside", startTime: 0, endTime: 60)])
        let playlist = RegionPlaylist(id: UUID(), name: "Empty playlist", songId: populatedSong.id, regionIds: [])
        var state = RegionSetlist()
        state.playlists = [playlist]
        XCTAssertEqual(text(populatedSong, state, playlist: playlist.id), "Empty playlist\nTotal duration: 00:00:00")
        state.playlists[0].regionIds = [UUID()]
        XCTAssertEqual(text(populatedSong, state, playlist: playlist.id), "Empty playlist\nTotal duration: 00:00:00")
    }

    func testMissingAndOtherSongPlaylistsProduceNoText() {
        let song = song([Part(id: UUID(), name: "Outside", startTime: 0, endTime: 60)])
        let otherSong = RegionPlaylist(id: UUID(), name: "Other song", songId: UUID(), regionIds: [])
        var state = RegionSetlist()
        state.playlists = [otherSong]
        XCTAssertEqual(text(song, state, playlist: UUID()), "")
        XCTAssertEqual(text(song, state, playlist: otherSong.id), "")
    }

    func testInvalidBoundsDoNotCorruptTheTotal() {
        let parts = [Part(id: UUID(), name: "Valid", startTime: 0, endTime: 2.9),
                     Part(id: UUID(), name: "Negative", startTime: 10, endTime: 5),
                     Part(id: UUID(), name: "Infinite", startTime: 20, endTime: .infinity),
                     Part(id: UUID(), name: "Unknown", startTime: 30, endTime: .nan)]
        XCTAssertEqual(text(song(parts)), """
        All regions
        Total duration: 00:00:02

        01. VALID
        02. NEGATIVE
        03. INFINITE
        04. UNKNOWN
        """)
    }
}
