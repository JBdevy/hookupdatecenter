import Foundation

private struct RowID { let id: UUID }
private struct TestTrack { let id: UUID; var clips: [RowID] }
private struct TestSong { let id: UUID; var tracks: [TestTrack] }
private struct TestProject { var id: UUID }
private struct TestSnapshot { var project: TestProject }
private final class ShowController {
    var snapshot: TestSnapshot
    var current: TestSong?
    var selectedRegionPlaylist: RowID?
    var listedBlocks: [RowID]
    var regions: Set<UUID>
    var focusedRegion: UUID?
    var selectedBlock: UUID?
    var deletedEntries: [Set<UUID>] = []
    var deletedItems: [Set<UUID>] = []
    var setlistEntries: [RowID] { listedBlocks + regions.map(RowID.init) }
    init(project: UUID, song: TestSong, playlist: UUID, blocks: [UUID], regions: [UUID]) {
        snapshot = .init(project: .init(id: project)); current = song
        selectedRegionPlaylist = .init(id: playlist); listedBlocks = blocks.map(RowID.init)
        self.regions = Set(regions); focusedRegion = regions.first
    }
    func selectSetlistBlock(_ id: UUID?) { selectedBlock = id.flatMap { candidate in listedBlocks.contains { $0.id == candidate } ? candidate : nil } }
    func deletableSetlistEntries(_ ids: Set<UUID>) -> Set<UUID> { ids.intersection(regions.union(listedBlocks.map(\.id))) }
    func deleteSetlistEntries(_ ids: Set<UUID>) -> Bool {
        let targets = deletableSetlistEntries(ids); guard !targets.isEmpty else { return false }
        deletedEntries.append(targets); listedBlocks.removeAll { targets.contains($0.id) }; regions.subtract(targets)
        return true
    }
    func deleteItems(_ ids: Set<UUID>) { deletedItems.append(ids) }
}
private struct TestState { var project: UUID; var song: UUID; var selectedPlaylist: UUID?; var setlistBlocks: [RowID]?; var playing = false }
private struct TestRow { let region: RowID }
private enum TestEntry { case region(TestRow), block(RowID) }
private final class TestRows {
    var values: [TestEntry]
    var lastQuery: String?
    var lastExpanded: Set<UUID>?
    init(values: [TestEntry]) { self.values = values }
    func entries(in state: TestState, expanded: Set<UUID>, query: String) -> [TestEntry] {
        lastQuery = query; lastExpanded = expanded
        return query.isEmpty ? values : []
    }
}
private final class RemoteMIDIActions { static let shared = RemoteMIDIActions(); var isLearning = false }
private final class TestItemSelection {
    var items: Set<UUID> = []
    func retain(_ ids: Set<UUID>) { items.formIntersection(ids) }
}
private final class TestScrolling {
    enum SelectionScope { case grid, tracks, setlist }
    var selectionScope = SelectionScope.grid
    var itemSelection = TestItemSelection()
}
private final class WorkspaceProbe {
    var local = true
    var observer = false
    var controlsEnabled = true
    var remoteMIDISetlistID: UUID?
    var localShow: ShowController?
    var state: TestState
    var selectedSetlistEntries: Set<UUID> = []
    var draggingSetlistEntries: Set<UUID> = []
    var setlistSelectionAnchor: UUID?
    var selectedTracks: Set<UUID> = []
    var visibleTracks: [TestTrack]
    var trackScrolling = TestScrolling()
    var hardwareModifiers: HardwareKeyboardModifiers = []
    var setlistRowsCache: TestRows
    var expandedRegions: Set<UUID> = []
    var search = ""
    var removal: Int?
    var confirmingRemoval = false
    var trackRequests: [Set<UUID>] = []
    var regionActions: [UUID] = []
    enum Action { case selectRegion }
    func action(_ action: Action, target: UUID) { regionActions.append(target); localShow?.focusedRegion = target }
    func requestNativeTrackDeletion(_ ids: Set<UUID>) { trackRequests.append(ids) }
    init() {
        let project = UUID(), song = UUID(), playlist = UUID(), region = UUID(), block = UUID(), secondBlock = UUID(), track = UUID(), clip = UUID()
        visibleTracks = [.init(id: track, clips: [.init(id: clip)])]
        state = .init(project: project, song: song, selectedPlaylist: playlist, setlistBlocks: [.init(id: block), .init(id: secondBlock)])
        localShow = .init(project: project, song: .init(id: song, tracks: visibleTracks), playlist: playlist, blocks: [block, secondBlock], regions: [region])
        setlistRowsCache = .init(values: [.block(.init(id: block)), .region(.init(region: .init(id: region))), .block(.init(id: secondBlock))])
        selectedTracks = [track]; trackScrolling.itemSelection.items = [clip]
    }
    // PRODUCTION_NATIVE_SETLIST_REMOVAL
    var nativeSetlistRemoval: NativeSetlistRemoval?
    // PRODUCTION_NATIVE_SETLIST_ACTIONS
}

@main private struct IpadSetlistBlockDeletionTests {
    static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) { checks += 1; precondition(condition(), message) }
        do {
            let view = WorkspaceProbe(), show = view.localShow!
            let block = show.listedBlocks[0].id, song = show.focusedRegion!
            view.trackScrolling.selectionScope = .tracks
            view.selectSetlistEntry(block)
            expect(view.trackScrolling.selectionScope == .setlist, "A block click must become the last selected area")
            expect(view.selectedSetlistEntries == [block] && show.selectedBlock == block, "A block must be an independently selected header")
            expect(view.regionActions.isEmpty && show.focusedRegion == song, "Selecting a block must not send a region/queue command")
            view.deleteNativeSelection()
            expect(view.nativeSetlistRemoval?.ids == [block] && view.nativeSetlistRemoval?.blocksOnly == true, "Delete must target the selected header, not the previously focused song")
            expect(show.deletedEntries.isEmpty && view.confirmingRemoval, "Deletion waits for confirmation")
            expect(view.trackRequests.isEmpty && show.deletedItems.isEmpty, "Old track/grid selections must remain untouched")
            view.confirmNativeSetlistRemoval()
            expect(show.deletedEntries == [[block]] && show.regions.contains(song), "Only the header ID reaches the project deletion API")
            expect(view.selectedSetlistEntries.isEmpty && !view.confirmingRemoval, "Confirmation clears the deleted selection")
            view.deleteNativeSelection()
            expect(view.nativeSetlistRemoval == nil && show.deletedEntries.count == 1, "Repeated Delete must not fall back to the old focused song")
        }
        for scope in [TestScrolling.SelectionScope.tracks, .grid] {
            let view = WorkspaceProbe(), show = view.localShow!
            view.selectSetlistEntry(show.listedBlocks[0].id)
            view.trackScrolling.selectionScope = scope
            view.deleteNativeSelection()
            expect(view.nativeSetlistRemoval == nil && show.deletedEntries.isEmpty, "Clicking another area must supersede the retained block selection")
            expect(scope == .tracks ? view.trackRequests == [view.selectedTracks] : show.deletedItems == [view.trackScrolling.itemSelection.items], "Delete follows the most recently selected track/grid area")
        }
        do {
            let view = WorkspaceProbe(), show = view.localShow!
            let blocks = show.listedBlocks.map(\.id)
            view.selectSetlistEntry(blocks[0]); view.hardwareModifiers = .command; view.selectSetlistEntry(blocks[1])
            view.deleteNativeSelection()
            expect(view.nativeSetlistRemoval?.ids == Set(blocks) && view.nativeSetlistRemoval?.blocksOnly == true, "Command selection supports multiple block headers")
            view.confirmNativeSetlistRemoval()
            expect(show.deletedEntries == [Set(blocks)] && show.regions.count == 1, "Multiple headers use one deletion and preserve songs")
        }
        do {
            let view = WorkspaceProbe(), show = view.localShow!
            let first = show.listedBlocks[0].id, last = show.listedBlocks[1].id
            view.selectSetlistEntry(first); view.hardwareModifiers = .shift; view.selectSetlistEntry(last)
            view.deleteNativeSelection()
            expect(view.nativeSetlistRemoval?.ids == Set([first, last, show.focusedRegion!]), "Shift range includes visible headers and songs in list order")
            expect(view.nativeSetlistRemoval?.blocksOnly == false, "A mixed selection must not promise to remove headers only")
        }
        for switchScope in 0..<3 {
            let view = WorkspaceProbe(), show = view.localShow!
            view.requestNativeSetlistRemoval([show.listedBlocks[0].id])
            if switchScope == 0 { show.snapshot.project.id = UUID() }
            else if switchScope == 1 { show.current = .init(id: UUID(), tracks: []) }
            else { show.selectedRegionPlaylist = .init(id: UUID()) }
            view.confirmNativeSetlistRemoval()
            expect(show.deletedEntries.isEmpty && view.nativeSetlistRemoval == nil, "A pending confirmation must not affect another project, song or playlist")
        }
        do {
            let view = WorkspaceProbe(), show = view.localShow!
            let block = show.listedBlocks[1].id
            view.trackScrolling.selectionScope = .grid
            view.requestNativeSetlistRemoval([block]) // Context-menu action receives its own header identity.
            expect(view.trackScrolling.selectionScope == .setlist && view.nativeSetlistRemoval?.ids == [block], "Context-menu removal must use the clicked header even with stale grid selection")
            view.confirmNativeSetlistRemoval()
            expect(show.deletedItems.isEmpty && view.trackRequests.isEmpty, "Context-menu deletion cannot affect grid or mixer")
            view.requestNativeSetlistRemoval([UUID()])
            expect(view.nativeSetlistRemoval == nil, "Stale/non-visible entries cannot be deleted")
            view.local = false; view.requestNativeSetlistRemoval([show.listedBlocks[0].id])
            expect(view.nativeSetlistRemoval == nil, "Native block edits must not mutate Remote state")
        }
        do {
            let view = WorkspaceProbe(), show = view.localShow!
            let blocks = Set(show.listedBlocks.map(\.id))
            view.selectedSetlistEntries = blocks
            view.trackScrolling.selectionScope = .tracks
            expect(view.prepareNativeSetlistDrag(blocks.first!), "A selected block must start a playlist drag")
            expect(view.draggingSetlistEntries == blocks && view.selectedSetlistEntries == blocks, "Starting on a selected block must preserve the whole block selection")
            expect(view.trackScrolling.selectionScope == .setlist, "Dragging a block must make the setlist the last selected area")
            expect(view.regionActions.isEmpty, "Dragging a block must not focus or queue a song")
        }
        do {
            let view = WorkspaceProbe(), show = view.localShow!
            let block = show.listedBlocks[0].id, region = show.regions.first!, stale = UUID()
            view.selectedSetlistEntries = [block, region, stale]
            expect(view.prepareNativeSetlistDrag(region), "A song in a mixed selection must also start the common drag")
            expect(view.draggingSetlistEntries == [block, region], "A mixed block/song batch must retain both entries and discard stale IDs")
            expect(view.selectedSetlistEntries == [block, region], "Only entries actually in the playlist remain selected")
            let other = show.listedBlocks[1].id
            expect(view.prepareNativeSetlistDrag(other), "An unselected block can start its own drag")
            expect(view.draggingSetlistEntries == [other] && view.selectedSetlistEntries == [other], "Dragging one block must move only that entry, never the songs below it")
            expect(view.setlistSelectionAnchor == other && show.selectedBlock == other, "A new single-block drag updates the keyboard selection anchor")
        }
        for invalidContext in 0..<6 {
            let view = WorkspaceProbe(), show = view.localShow!
            let block = show.listedBlocks[0].id
            view.draggingSetlistEntries = [block]
            switch invalidContext {
            case 0: view.local = false
            case 1: view.state.selectedPlaylist = nil
            case 2: show.snapshot.project.id = UUID()
            case 3: show.current = .init(id: UUID(), tracks: [])
            case 4: show.selectedRegionPlaylist = .init(id: UUID())
            default: show.listedBlocks.removeAll()
            }
            expect(!view.prepareNativeSetlistDrag(block), "A Remote, All regions, switched project/song/playlist or stale row cannot start a native reorder")
            expect(view.draggingSetlistEntries.isEmpty, "A rejected drag must not leave an old batch available to the next drop")
        }
        do {
            let view = WorkspaceProbe(), show = view.localShow!
            view.local = false
            let first = show.listedBlocks[0].id, second = show.listedBlocks[1].id
            let firstSong = show.regions.first!, secondSong = UUID(), trailingBlock = UUID()
            view.setlistRowsCache.values = [.block(.init(id:first)), .region(.init(region:.init(id:firstSong))),
                .block(.init(id:second)), .region(.init(region:.init(id:secondSong))), .block(.init(id:trailingBlock))]
            view.search = "a filter that hides every row"; view.expandedRegions = [UUID()]
            expect(view.remoteSetlistBlockNumber(second) == 2, "Searching must not renumber a block's global MIDI ID")
            expect(view.setlistRowsCache.lastQuery == "" && view.setlistRowsCache.lastExpanded == [], "Block numbering uses the complete playlist, excluding drawer children")
            for playing in [false, true] {
                view.state.playing = playing
                let before = view.regionActions.count
                view.performRemoteBlockMIDI(2)
                expect(view.regionActions.count == before + 1 && view.regionActions.last == secondSong, "Stopped and playing Remote both use the same single selectRegion command as a song click, without an additional Play")
                expect(view.selectedSetlistEntries == [secondSong] && view.remoteMIDISetlistID == secondSong, "Remote block MIDI updates the song selection and navigation anchor")
            }
            let beforeEmpty = view.regionActions.count
            for number in [0, 3, 4, 129] { view.performRemoteBlockMIDI(number) }
            expect(view.regionActions.count == beforeEmpty, "An invalid/missing ID or trailing block without a song is a no-op")
            let newBlock = UUID(), newSong = UUID()
            view.state.project = UUID(); view.state.selectedPlaylist = UUID()
            view.setlistRowsCache.values = [.block(.init(id:newBlock)), .region(.init(region:.init(id:newSong)))]
            view.performRemoteBlockMIDI(1)
            expect(view.regionActions.last == newSong, "The same global ID resolves the latest host/project/playlist entries rather than a learned UUID")
            view.setlistRowsCache.values = [.block(.init(id:first)), .block(.init(id:second)), .region(.init(region:.init(id:secondSong)))]
            view.performRemoteBlockMIDI(1)
            expect(view.regionActions.last == secondSong, "Consecutive blocks resolve the first song below them, matching desktop")
            let beforeBlocked = view.regionActions.count
            RemoteMIDIActions.shared.isLearning = true; view.performRemoteBlockMIDI(1)
            RemoteMIDIActions.shared.isLearning = false
            view.observer = true; view.performRemoteBlockMIDI(1); view.observer = false
            view.controlsEnabled = false; view.performRemoteBlockMIDI(1); view.controlsEnabled = true
            view.local = true; view.performRemoteBlockMIDI(1); view.local = false
            view.state.selectedPlaylist = nil; view.performRemoteBlockMIDI(1)
            expect(view.regionActions.count == beforeBlocked, "Learning, Observer, disabled control, native mode and All regions cannot send Remote block commands")
        }
        print("PASS iPad block selection, Delete, drag batches and Remote MIDI ordinal resolution: \(checks) assertions")
    }
}
