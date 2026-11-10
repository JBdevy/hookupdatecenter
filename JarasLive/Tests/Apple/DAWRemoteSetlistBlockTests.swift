// Block separators are independent presentation entries. They keep playlist
// order, do not consume song numbers and never acquire playback commands.
var blockFixture = drawerFixture
let blockA = UUID(), blockB = UUID(), blockC = UUID(), blockTail = UUID()
blockFixture.setlistBlocks = [
    .init(id: blockA, name: "Abertura", color: 0xffcc00, beforeRegion: regionID),
    .init(id: blockB, name: "Consecutivo", color: 0x00bb77, beforeRegion: regionID, symbol: false),
    .init(id: blockC, name: "Segundo bloco", color: 0x2266cc, beforeRegion: plainRegion),
    .init(id: blockTail, name: "Fim", color: 0xaa44cc, beforeRegion: nil)
]
let blockCache = DAWRemoteSetlistRowsCache()
let blockEntries = blockCache.entries(in: blockFixture, expanded: [regionID], query: "")
require(blockEntries.map(\.id) == [.block(blockA), .block(blockB), .region(regionID), .region(drawerChild), .block(blockC), .region(plainRegion), .block(blockTail)],
    "Consecutive blocks precede their anchor, drawer children stay together and final blocks remain at the end")
let numberedRows = blockEntries.compactMap { entry -> DAWRemoteSetlistPresentation.Row? in if case .region(let row) = entry { return row }; return nil }
require(numberedRows.map(\.number) == [1, nil, 2], "Separators and drawer children never increment song numbering")
for index in 0..<100 {
    blockFixture.position = Double(index) / 20
    _ = blockCache.entries(in: blockFixture, expanded: [regionID], query: "")
}
require(blockCache.rebuildCount == 1, "Transport packets reuse cached block and region entries")
blockFixture.setlistBlocks![0].name = "Novo nome"; blockFixture.setlistBlocks![0].color = 0x123456
if case .block(let first) = blockCache.entries(in: blockFixture, expanded: [regionID], query: "")[0] {
    require(first.name == "Novo nome" && first.color == 0x123456, "Changing a block name/color updates its cached header")
} else { fatalError("block entry expected") }
require(blockCache.rebuildCount == 2, "One block edit rebuilds presentation once")
let searchEntries = blockCache.entries(in: blockFixture, expanded: [regionID], query: "Regular")
require(searchEntries.map(\.id) == [.block(blockC), .region(plainRegion)], "Searching a song retains its block header")
let headerSearch = blockCache.entries(in: blockFixture, expanded: [], query: "Novo nome")
require(headerSearch.map(\.id) == [.block(blockA), .block(blockB), .region(regionID)], "Searching a header shows that block's songs without opening a drawer")
blockFixture.selectedPlaylist = UUID(); blockFixture.regions.reverse()
blockFixture.setlistBlocks = [.init(id: blockTail, name: "Outra playlist", color: 0xabcdef, beforeRegion: plainRegion)]
require(blockCache.entries(in: blockFixture, expanded: [], query: "").map(\.id) == [.block(blockTail), .region(plainRegion), .region(regionID)],
    "Playlist switches replace old separators and preserve the host's explicit song order")
if case .state(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.state(blockFixture)) {
    require(decoded.setlistBlocks == blockFixture.setlistBlocks, "Header identity, order, symbol, color and anchors roundtrip")
} else { fatalError("block wire packet") }
var legacyBlockJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(blockFixture)) as! [String: Any]
legacyBlockJSON.removeValue(forKey: "setlistBlocks")
let oldBlockState = try JSONDecoder().decode(DAWRemoteState.self, from: JSONSerialization.data(withJSONObject: legacyBlockJSON))
require(oldBlockState.setlistBlocks == nil, "Older hosts without block metadata remain compatible")
var invalidBlocks = blockFixture
invalidBlocks.setlistBlocks!.append(invalidBlocks.setlistBlocks![0])
require(!invalidBlocks.valid, "Duplicate block identities are rejected")
invalidBlocks = blockFixture; invalidBlocks.setlistBlocks![0].color = 0x1000000
require(!invalidBlocks.valid, "Invalid block colors are rejected")
var onlyBlocks = blockFixture; onlyBlocks.regions = []; onlyBlocks.timelineRegions = []
onlyBlocks.setlistBlocks = [.init(id: blockTail, name: "Empty final block", color: 0x123456, beforeRegion: nil)]
require(blockCache.entries(in: onlyBlocks, expanded: [], query: "").map(\.id) == [.block(blockTail)], "Empty/end-only blocks are displayed even without song rows")

// Verify the actual host-side role filter transmits headers to Observer while
// continuing to reject forged playback/selection controls and strip mixer data.
let blockHost = DAWRemoteSession(role: .host, name: "Block host")
let blockClient = DAWRemoteSession(role: .client, name: "Block observer")
let blockEndpoint = try blockHost.testListen()
var networkBlocks = blockFixture
var blockCommands = 0
blockHost.stateProvider = { networkBlocks }
blockHost.commandHandler = { _ in blockCommands += 1 }
blockClient.testConnect(blockEndpoint, access: .observer)
waitFor("observer receives playlist block headers") { blockClient.remoteState?.setlistBlocks == networkBlocks.setlistBlocks }
require(blockClient.remoteState?.tracks.isEmpty == true && blockClient.remoteState?.playlists == nil,
    "Block presentation does not expose mixer or playlist control state to Observer")
blockClient.testUnchecked(.init(project: project, action: .play))
blockClient.testUnchecked(.init(project: project, action: .selectRegion, target: plainRegion))
networkBlocks.setlistBlocks![0].name = "Renamed over connection"
waitFor("observer receives block rename") { blockClient.remoteState?.setlistBlocks?.first?.name == "Renamed over connection" }
require(blockCommands == 0, "Showing block headers never permits Observer playback/selection commands")
networkBlocks.selectedPlaylist = UUID(); networkBlocks.regions.reverse()
networkBlocks.setlistBlocks = [.init(id: blockB, name: "Another list", color: 0xabcdef, beforeRegion: regionID, symbol: false)]
waitFor("observer receives replacement playlist blocks and order") {
    blockClient.remoteState?.setlistBlocks == networkBlocks.setlistBlocks && blockClient.remoteState?.regions == networkBlocks.regions
}
// Live history must survive the Observer role filter just like block headers.
// Completion belongs to the desktop controller: a single played child cannot
// turn its parent/siblings into completed songs during remote presentation.
let secondPlayedChild = UUID()
networkBlocks.timelineRegions.append(.init(id: secondPlayedChild, name: "Second drawer song", start: 5, end: 9,
    color: 0x123456, parentRegion: regionID))
networkBlocks.setlistLiveEnabled = true
networkBlocks.playedLiveRegionIDs = [drawerChild]
waitFor("observer receives individual played drawer song") {
    blockClient.remoteState?.setlistLiveEnabled == true && blockClient.remoteState?.playedLiveRegionIDs == [drawerChild]
}
let liveRowsCache = DAWRemoteSetlistRowsCache()
let liveRows = liveRowsCache.rows(in: blockClient.remoteState!, expanded: [regionID], query: "")
let initialMarks = Set(blockClient.remoteState!.playedLiveRegionIDs ?? [])
require(liveRows.filter { initialMarks.contains($0.id) }.map(\.id) == [drawerChild],
    "Observer presents only the completed drawer child; parent and unplayed sibling remain unmarked")
networkBlocks.playedLiveRegionIDs = [regionID, drawerChild, secondPlayedChild]
waitFor("observer receives completed unified region and all children") {
    Set(blockClient.remoteState?.playedLiveRegionIDs ?? []) == Set([regionID, drawerChild, secondPlayedChild])
}
let completedMarks = Set(blockClient.remoteState!.playedLiveRegionIDs ?? [])
require(liveRowsCache.rows(in: blockClient.remoteState!, expanded: [regionID], query: "").filter { completedMarks.contains($0.id) }.map(\.id) == [regionID, drawerChild, secondPlayedChild],
    "Once the desktop completes every child, Observer marks the wrapper and each child individually")
require(liveRowsCache.rebuildCount == 1, "Live marks update row presentation without rebuilding structural list caches")
networkBlocks.setlistLiveEnabled = false; networkBlocks.playedLiveRegionIDs = []
waitFor("disabling Live clears Observer marks") {
    blockClient.remoteState?.setlistLiveEnabled == false && blockClient.remoteState?.playedLiveRegionIDs == []
}
blockClient.testUnchecked(.init(project: project, action: .toggleSetlistLive))
networkBlocks.message = "Live clear observed"
waitFor("observer still receives state after forbidden Live toggle") { blockClient.remoteState?.message == "Live clear observed" }
require(blockCommands == 0 && blockClient.remoteState?.playedLiveRegionIDs == [],
    "Observer sees Live history but cannot enable/disable Live or restore cleared markings")
print("REMOTE_OBSERVER_LIVE_CHILD_PARENT_COMPLETION_RESET_CACHED_ROWS_AND_READ_ONLY_OK")
// Host keyboard/MIDI navigation publishes focus independently of playback and
// queue. The same state provider serves desktop and native iPad hosts.
let browsedSong = UUID()
networkBlocks.regions.append(.init(id: browsedSong, name: "Browsing", start: 0, end: 10, color: 0x123456))
networkBlocks.playing = true; networkBlocks.currentRegion = regionID
networkBlocks.queuedRegion = plainRegion; networkBlocks.focusedRegion = browsedSong
waitFor("observer sees browsing while another song plays and a third is queued") {
    blockClient.remoteState?.focusedRegion == browsedSong && blockClient.remoteState?.playing == true
}
let browsingSnapshot = blockClient.remoteState!
require(DAWRemoteSetlistPresentation.observerFocus(in: browsingSnapshot, expanded: []) == browsedSong &&
        browsingSnapshot.setlistCurrentEntryId == regionID && browsingSnapshot.setlistQueuedEntryId == plainRegion,
        "Blue browsing, red playback and orange queue have independent entry identities")
networkBlocks.focusedRegion = drawerChild
waitFor("focus-only packet reaches observer during playback") { blockClient.remoteState?.focusedRegion == drawerChild }
require(DAWRemoteSetlistPresentation.observerFocus(in: blockClient.remoteState!, expanded: []) == regionID,
        "A collapsed drawer reveals its focused child's parent")
require(DAWRemoteSetlistPresentation.observerFocus(in: blockClient.remoteState!, expanded: [regionID]) == drawerChild,
        "An expanded drawer selects only the child instead of two blue rows")
networkBlocks.focusedRegion = browsedSong
networkBlocks.subPlaying = true
waitFor("observer browsing remains visible with SubPlay") { blockClient.remoteState?.subPlaying == true && blockClient.remoteState?.focusedRegion == browsedSong }
require(DAWRemoteSetlistPresentation.observerFocus(in: blockClient.remoteState!, expanded: []) == browsedSong,
        "SubPlay does not hide browsing")
require(blockCommands == 0 && blockClient.remoteState?.currentRegion == regionID && blockClient.remoteState?.queuedRegion == plainRegion,
        "Following focus neither controls the host nor replaces its playback/queue")
networkBlocks.playing = false; networkBlocks.subPlaying = false; networkBlocks.focusedRegion = nil
waitFor("clearing focus clears the observer highlight") { blockClient.remoteState?.focusedRegion == nil && blockClient.remoteState?.playing == false }
require(DAWRemoteSetlistPresentation.observerFocus(in: blockClient.remoteState!, expanded: []) == nil,
        "Empty focus does not invent a selected row")
var duplicateFocus = browsingSnapshot
let duplicateFocusID = UUID()
var focusCopy = duplicateFocus.regions.first { $0.id == browsedSong }!
focusCopy.id = duplicateFocusID; focusCopy.sourceRegionId = browsedSong
duplicateFocus.regions.append(focusCopy); duplicateFocus.focusedRegion = duplicateFocusID
require(DAWRemoteSetlistPresentation.observerFocus(in: duplicateFocus, expanded: []) == duplicateFocusID,
        "A playlist copy keeps its own blue selection without highlighting the source")
print("REMOTE_OBSERVER_BROWSING_PLAYING_QUEUED_DRAWERS_COPIES_AND_READ_ONLY_OK")
blockClient.requestAccess(.notices)
waitFor("notices-only role removes block metadata") { blockClient.accessMode == .notices && blockClient.remoteState?.setlistBlocks == nil }
blockClient.stop(); blockHost.stop()
print("REMOTE_SETLIST_BLOCKS_OBSERVER_WIRE_ORDER_DRAWERS_NUMBERS_SEARCH_CACHE_RENAME_PLAYLIST_AND_READ_ONLY_OK")

// A playlist copy has a row identity while the audio/grid still use the original region.
var repeatedFixture = drawerFixture
let duplicateRowID = UUID(), repeatedPlaylistID = UUID()
var copiedRow = repeatedFixture.regions[0]
copiedRow.id = duplicateRowID; copiedRow.sourceRegionId = repeatedFixture.regions[0].id
repeatedFixture.regions.insert(copiedRow, at: 1)
repeatedFixture.selectedPlaylist = repeatedPlaylistID
repeatedFixture.currentPlaylistEntryId = duplicateRowID
repeatedFixture.currentRegion = copiedRow.sourceRegionId
repeatedFixture.queuedPlaylistEntryId = duplicateRowID
repeatedFixture.queuedRegion = copiedRow.sourceRegionId
let repeatedRows = DAWRemoteSetlistPresentation.rows(in: repeatedFixture, expanded: [duplicateRowID], query: "")
require(repeatedRows.map(\.id) == [regionID, duplicateRowID, plainRegion], "Playlist copy retains a unique row and does not repeat drawer children")
require(repeatedFixture.timelineRegions == drawerFixture.timelineRegions, "Setlist copy does not create timeline regions")
require(repeatedFixture.setlistCurrentEntryId == duplicateRowID && repeatedFixture.setlistQueuedEntryId == duplicateRowID, "Playback highlights the copy only")
if case .state(let decoded) = try DAWRemoteWire.decode(DAWRemoteWire.state(repeatedFixture)) {
    require(decoded.regions == repeatedFixture.regions && decoded.currentPlaylistEntryId == duplicateRowID && decoded.queuedPlaylistEntryId == duplicateRowID, "Duplicate metadata survives Remote serialization")
} else { fatalError("duplicate state packet") }
let duplicateCommand = DAWRemoteCommand(project: project, song: song, action: .duplicateRegion, target: regionID, playlist: repeatedPlaylistID)
require(duplicateCommand.valid && DAWRemoteAccessRules.allows(duplicateCommand, mode: .director), "Director can duplicate a named playlist entry")
require(!DAWRemoteAccessRules.allows(duplicateCommand, mode: .observer), "Observer cannot create copies")
var allRegionsDuplicate = duplicateCommand; allRegionsDuplicate.playlist = nil
require(!allRegionsDuplicate.valid, "All regions cannot request a duplicate")
print("REMOTE_PLAYLIST_DUPLICATE_IDENTITY_AND_PERMISSIONS_OK")

repeatedFixture.playing = false
require(DAWRemoteSetlistPresentation.canQueueDuplicate(duplicateRowID, in: repeatedFixture), "Copy is allowed while stopped")
repeatedFixture.playing = true
require(!DAWRemoteSetlistPresentation.canQueueDuplicate(duplicateRowID, in: repeatedFixture), "Copy warns when its physical source is playing")
repeatedFixture.currentRegion = plainRegion
require(DAWRemoteSetlistPresentation.canQueueDuplicate(duplicateRowID, in: repeatedFixture), "Copy may queue while another song plays")
repeatedFixture.subPlaying = true
require(!DAWRemoteSetlistPresentation.canQueueDuplicate(duplicateRowID, in: repeatedFixture), "Copy warns when its source is already in Subplay")
require(DAWRemoteSetlistPresentation.canQueueDuplicate(plainRegion, in: repeatedFixture), "Normal rows retain their existing selection rules")

// No packet is needed at the boundary; late outgoing packets must not flash
// the old blue selection back. Host confirmation remains authoritative.
var localBlock = drawerFixture
let localFirst = UUID(), localNext = UUID()
localBlock.regions = [.init(id: localFirst, name: "First", start: 30, end: 40, color: 0),
                      .init(id: localNext, name: "Next", start: 4, end: 14, color: 0)]
localBlock.timelineRegions = localBlock.regions
localBlock.selectedPlaylist = UUID(); localBlock.currentRegion = localFirst
localBlock.currentPlaylistEntryId = localFirst
localBlock.playing = true; localBlock.paused = false; localBlock.subPlaying = false; localBlock.loop = false
localBlock.position = 39; localBlock.playbackEnd = 40; localBlock.queuedRegion = nil
localBlock.regionAuto = false; localBlock.regionAutoUntilBlockEnd = true; localBlock.sectionPlayback = nil
localBlock.setlistBlocks = [.init(id: UUID(), name: "Next block", color: 0, beforeRegion: localNext)]
var localFeedback = DAWRemoteBlockFeedback()
require(localFeedback.receive(localBlock, now: 10).playing, "Remote keeps playing until the actual boundary")
require(localFeedback.advance(now: 10.99) == nil, "Remote cannot prepare the next block early")
let localPrepared = localFeedback.advance(now: 11)!
require(!localPrepared.playing && localPrepared.focusedRegion == localNext && localPrepared.position == 4 && localPrepared.editPosition == 4,
        "Remote locally prepares the next block's blue selection and both cursors without AUTO")
localBlock.position = 39.9
require(!localFeedback.receive(localBlock, now: 11.01).playing, "Delayed outgoing packet cannot undo local completion")
localBlock.position = 35
require(localFeedback.receive(localBlock, now: 11.02).playing, "A seek invalidates local completion")
for field in 0..<5 {
    var changed = localBlock
    switch field {
    case 0: changed.loop = true
    case 1: changed.subPlaying = true
    case 2: changed.queuedRegion = localNext
    case 3: changed.regionAutoUntilBlockEnd = false
    default: changed.playbackEnd = 42
    }
    require(DAWRemoteBlockPreparation(changed) == nil, "Loop/Subplay/manual queue/policy/ignore-next prohibit a predicted stop")
}
localFeedback.reset()
require(localFeedback.advance(now: 100) == nil, "Disconnect or local transport commands cancel pending prediction")
var confirmedBlock = localPrepared
confirmedBlock.focusedRegion = localFirst
require(localFeedback.receive(confirmedBlock, now: 20).focusedRegion == localFirst, "Authoritative stopped selection wins")
print("REMOTE_LOCAL_BLOCK_PREPARATION_CLOCK_RECONCILIATION_OK")

let preparationHost = DAWRemoteSession(role: .host, name: "Preparation host")
let preparationClient = DAWRemoteSession(role: .client, name: "Preparation client")
let preparationEndpoint = try preparationHost.testListen()
var preparationPacket = localBlock
preparationPacket.position = 39.85
var preparationCommands = 0
preparationHost.stateProvider = { preparationPacket }
preparationHost.commandHandler = { _ in preparationCommands += 1 }
preparationClient.testConnect(preparationEndpoint, access: .director)
waitFor("Remote receives the outgoing block song") { preparationClient.remoteState?.currentRegion == localFirst }
waitFor("Remote timer prepares next block without a stopped host packet") {
    preparationClient.remoteState?.focusedRegion == localNext && preparationClient.remoteState?.playing == false
}
require(preparationCommands == 0, "Local completion never sends Play, Stop or selection to the host")
preparationPacket = localPrepared
waitFor("Remote accepts host confirmation") { preparationClient.remoteState?.currentRegion == localNext }
preparationPacket = localBlock
preparationPacket.position = 35
waitFor("Remote receives a fresh playing block for manual Stop") { preparationClient.remoteState?.playing == true && preparationClient.remoteState?.position == 35 }
preparationClient.send(.init(project: preparationPacket.project, song: preparationPacket.song, action: .stop))
require(preparationClient.remoteState?.focusedRegion == localNext && preparationClient.remoteState?.gridRegion == localNext && preparationClient.remoteState?.playing == false, "Remote Stop selects and reveals synchronously before host acknowledgment")
waitFor("Remote sends exactly the requested Stop") { preparationCommands == 1 }
preparationPacket = localPrepared
waitFor("Remote accepts manual Stop confirmation") { preparationClient.remoteState?.currentRegion == localNext }
preparationClient.stop(); preparationHost.stop()
print("REMOTE_NETWORK_LOCAL_BLOCK_TIMER_NO_TRANSPORT_COMMANDS_OK")

// Stop must predict the same grid/blue selection before any host round trip.
var manualFeedback = DAWRemoteBlockFeedback()
let manualPrepared = manualFeedback.stop(localBlock, now: 50)!
require(manualPrepared.focusedRegion == localNext && manualPrepared.gridRegion == localNext && manualPrepared.editPosition == 4 && !manualPrepared.playing, "Manual Remote Stop immediately reveals the next block")
require(manualFeedback.receive(localBlock, now: 50.1).focusedRegion == localNext, "Late running packets cannot undo a requested Stop")
require(manualFeedback.receive(manualPrepared, now: 50.2).gridRegion == localNext, "Stopped host confirms next-block grid")
require(manualFeedback.stop(manualPrepared, now: 51) == nil, "Repeated idle Stop does not advance")
var pausedBlock = localBlock; pausedBlock.playing = false; pausedBlock.paused = true
require(manualFeedback.stop(pausedBlock, now: 52)?.focusedRegion == localNext, "Stop after Pause prepares next block")
_ = manualFeedback.stop(localBlock, now: 53)
require(manualFeedback.advance(now: 54.5)?.playing == true, "Unconfirmed manual prediction expires")
print("REMOTE_MANUAL_STOP_BLOCK_PREPARATION_OK")
