import Foundation

try MainActor.assumeIsolated {
    let controller = NSObject(), otherController = NSObject()
    let cache = SetlistEntryCache()
    let project = UUID(), song = UUID(), playlist = UUID()
    let first = Part(id: UUID(), name: "First", startTime: 0, endTime: 10)
    let second = Part(id: UUID(), name: "Second", startTime: 20, endTime: 30)
    var entries: [SetlistEntry] = [.region(first, number: 1), .region(second, number: 2)]
    var builds = 0
    func build() -> [SetlistEntry] { builds += 1; return entries }
    func key(projectID: UUID = project, revision: UInt64 = 0, setlist: UInt64 = 0, songID: UUID? = song, playlistID: UUID? = nil, owner: NSObject = controller, expanded: Set<UUID> = []) -> SetlistEntryCache.Key {
        SetlistEntryCache.Key(controller: ObjectIdentifier(owner), project: projectID, projectRevision: revision, setlistRevision: setlist, song: songID, playlist: playlistID, expanded: expanded)
    }
    let original = cache.entries(for: key(), build: build)
    let buffer = original.withUnsafeBufferPointer { $0.baseAddress }
    for frame in 0..<300 {
        let snapshot = cache.entries(for: key(), build: build)
        precondition(snapshot == original && snapshot.withUnsafeBufferPointer { $0.baseAddress } == buffer, "transport frame \(frame) reuses existing entry array storage")
    }
    precondition(builds == 1, "transport ticks must not repeatedly sort regions, group blocks or rebuild entries")
    let block = SetlistBlock(id: UUID(), songId: song, playlistId: playlist, name: "Block", color: 0x55ee88, beforeRegionId: second.id, symbol: true)
    entries = [.region(second, number: 1), .block(block), .region(first, number: 2)]
    precondition(cache.entries(for: key(setlist: 1, playlistID: playlist), build: build) == entries, "playlist ordering and newly edited blocks invalidate the structural cache")
    var renamed = second; renamed.name = "Renamed"; renamed.color = 0xff9900; renamed.endTime = 40
    entries = [.region(renamed, number: 1), .block(block), .region(first, number: 2)]
    precondition(cache.entries(for: key(revision: 1, setlist: 1, playlistID: playlist), build: build) == entries, "region name/color/duration edits update cached row metadata")
    entries = [.region(first, number: 1)]
    precondition(cache.entries(for: key(revision: 2, setlist: 1, playlistID: playlist), build: build) == entries, "undo/removal uses the new project revision")
    for next in [key(songID: UUID()), key(playlistID: UUID()), key(projectID: UUID()), key(owner: otherController), key(expanded: [first.id])] {
        let before = builds
        _ = cache.entries(for: next, build: build)
        precondition(builds == before + 1, "song, playlist, project, controller replacement and opening a drawer cannot retain stale structural entries")
    }
    print("SETLIST_STRUCTURAL_CACHE_300_TRANSPORT_FRAMES_SHARED_STORAGE_REVISIONS_AND_REPLACEMENT_OK")
}
