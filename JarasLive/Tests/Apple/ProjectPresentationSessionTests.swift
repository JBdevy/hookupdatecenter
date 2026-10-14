import Foundation

// Only the external provider/decoder surfaces are stand-ins. The production
// drop callback and video reset/status task are inserted by the harness.
struct Part { let id: UUID }
@MainActor final class ShowController {
    let current: Part? = Part(id: UUID()), selectedRegionPlaylist: Part? = Part(id: UUID())
    var projectSessionID = UUID()
    var moves = 0, completedDrops = 0
    func moveSetlistEntries(_ ids: Set<UUID>, relativeTo entry: UUID, after: Bool) { moves += 1 }
}
final class Provider {
    private var completion: ((String?, Error?) -> Void)?
    func loadObject(ofClass: String.Type, completionHandler: @escaping (String?, Error?) -> Void) -> Progress {
        completion = completionHandler
        return Progress(totalUnitCount: 1)
    }
    func complete(_ value: String) { completion?(value, nil); completion = nil }
}
struct DropInfo {
    let provider: Provider
    let location = CGPoint(x: 0, y: 20)
    func itemProviders(for: [String]) -> [Provider] { [provider] }
}
final class ReorderState {
    var scope: String?
    init(_ scope: String) { self.scope = scope }
    func finish() { scope = nil }
}
@MainActor struct DropFixture {
    static let type = "text"
    let show: ShowController, scope: String, entry: UUID
    let height = 34.0
    let state: ReorderState
    // INSERT_DROP
}
final class Player {
    var paused = false, item: Int? = 1
    func pause() { paused = true }
    func replaceCurrentItem(with value: Int?) { item = value }
}
@MainActor final class VideoFixture {
    var generation = UUID(), pendingSeek: (Double, Float)?, seeking = false
    let player = Player()
    var itemStatus: Int?, clipID: UUID?, playbackRate: Float = 0
    var lastPosition: Double?, lastSourcePosition: Double?
    var message = "", image: Int?, directory: URL?, snapshot: Int?
    // INSERT_VIDEO_RESET
    // INSERT_VIDEO_OPEN
    func queueStatusError(_ error: String?) -> Task<Void, Never> {
        // INSERT_VIDEO_STATUS
    }
}

Task { @MainActor in
    var failures = 0
    func check(_ value: Bool, _ message: String) {
        if !value { failures += 1; fputs("FAIL: \(message)\n", stderr) }
    }
    let directory = FileManager.default.temporaryDirectory
    let video = VideoFixture()
    video.message = "Previous project video could not open"
    video.image = 1; video.snapshot = 1; video.seeking = true
    video.open(directory: directory)
    check(video.message.isEmpty && video.image == nil && video.snapshot == nil && video.player.item == nil && !video.seeking,
          "Opening a project must retire the previous decoder, image, error and pending seek")
    let oldStatus = video.queueStatusError("Late status from previous project")
    video.open(directory: directory) // Same path/UUID still starts a new session.
    await oldStatus.value
    check(video.message.isEmpty, "An already queued error from the old AVPlayerItem must not enter the new session")
    await video.queueStatusError("Current item failed").value
    check(video.message == "Current item failed", "The current item's error must remain visible")

    let show = ShowController()
    let scope = show.current!.id.uuidString + ":" + show.selectedRegionPlaylist!.id.uuidString
    let payload = "jaras-setlist:" + scope + ":" + UUID().uuidString
    for replaceSession in [false, true] {
        let provider = Provider(), state = ReorderState(scope)
        let drop = DropFixture(show: show, scope: scope, entry: UUID(), state: state)
        let previousMoves = show.moves, previousCompletions = show.completedDrops
        check(drop.performDrop(info: DropInfo(provider: provider)), "Valid drop should start reading its provider")
        check(state.scope == nil, "The insertion indicator ends as soon as drop processing starts")
        if replaceSession { show.projectSessionID = UUID() } // Model UUIDs intentionally unchanged.
        provider.complete(payload)
        // The harness observes task completion even when the production guard
        // rejects the callback; no sleeps or provider scheduling race required.
        for _ in 0..<2_000 {
            if show.completedDrops > previousCompletions { break }
            await Task.yield()
        }
        check(show.completedDrops > previousCompletions, "The queued drop callback must finish")
        check(show.moves == previousMoves + (replaceSession ? 0 : 1),
              replaceSession ? "An old drop must not reorder a reopened same-UUID project" : "A drop in the current session must still reorder")
    }
    let song = UUID(), first = UUID(), second = UUID()
    let selection = AudioExportSelection.shared
    selection.setTracks([first], song: song); selection.setClips([second], song: song); selection.setRegions([first, second], song: song)
    selection.clear()
    check(selection.tracks(song).isEmpty && selection.clips(song).isEmpty && selection.regions(song).isEmpty,
          "Reopening the same song UUID cannot inherit any of the old export selections")
    selection.setClips([first], song: song)
    check(selection.clips(song) == [first], "New-session selection must work after reset")
    if failures == 0 { print("PROJECT_PRESENTATION_SESSION_RETIRES_VIDEO_ERRORS_STALE_DROPS_AND_EXPORT_SELECTIONS_OK") }
    exit(failures == 0 ? 0 : 1)
}
dispatchMain()
