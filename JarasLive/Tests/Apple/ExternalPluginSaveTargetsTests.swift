import Foundation

private struct Plugin { let id: String; var state: Int = 0 }
private struct FX { var externalPlugins: [Plugin]? }
private enum Kind { case standard, special }
private struct Track { let id: UUID; var kind: Kind = .standard; var fx: FX? }
private struct Song { var tracks: [Track] }
private struct Project { var masterFX: FX?; var songs: [Song] }
private struct Snapshot { var project: Project }
private enum CaptureFailure: Error { case rejected }

@MainActor private final class ShowController {
    var snapshot: Snapshot
    var currentSong: Int? = 0
    var current: Song? { currentSong.map { snapshot.project.songs[$0] } }
    var searches = 0
    var captures: [String] = []
    var rejected: String?
    var clips = 0
    init(_ tracks: [Track] = [], master: FX? = nil) {
        snapshot = Snapshot(project: Project(masterFX: master, songs: [Song(tracks: tracks)]))
    }
    // Match the former lookup: a whole-project flatten/search even for a row
    // without plugins. The production enumeration must never invoke it.
    func fxSettings(_ id: UUID?) -> FX {
        searches += 1
        return id.flatMap { id in snapshot.project.songs.flatMap(\.tracks).first { $0.id == id }?.fx }
            ?? (id == nil ? snapshot.project.masterFX : nil) ?? FX()
    }
}
@MainActor private enum ClipExternalPluginHostView {
    static func captureAllForSaving(show: ShowController) throws {
        if show.rejected == "clip" { throw CaptureFailure.rejected }
        show.clips += 1
    }
}
@MainActor private enum ExternalPluginState {
    static func captureForSaving(show: ShowController, track: UUID?, identifier: String) throws {
        if show.rejected == identifier { throw CaptureFailure.rejected }
        show.captures.append((track?.uuidString ?? "master") + ":" + identifier)
        // The real capture reads live plugin state at invocation. Ensure the
        // target enumeration never overwrites earlier captures with a snapshot.
        if let track {
            let index = show.snapshot.project.songs[0].tracks.firstIndex { $0.id == track }!
            let plugin = show.snapshot.project.songs[0].tracks[index].fx!.externalPlugins!.firstIndex { $0.id == identifier }!
            show.snapshot.project.songs[0].tracks[index].fx!.externalPlugins![plugin].state += 1
        } else {
            let index = show.snapshot.project.masterFX!.externalPlugins!.firstIndex { $0.id == identifier }!
            show.snapshot.project.masterFX!.externalPlugins![index].state += 1
        }
    }
PRODUCTION_CAPTURE_ALL
}

MainActor.assumeIsolated {
    let empty = ShowController((0..<4000).map { _ in Track(id: UUID()) })
    try! ExternalPluginState.captureAllForSaving(show: empty)
    precondition(empty.searches == 0 && empty.captures.isEmpty && empty.clips == 1,
                 "thousands of plugin-free tracks must not perform whole-project FX lookups")

    let a = Track(id: UUID(), fx: FX(externalPlugins: [Plugin(id: "a1"), Plugin(id: "a2")]))
    let b = Track(id: UUID(), fx: FX(externalPlugins: [Plugin(id: "b")]))
    let ignored = Track(id: UUID(), kind: .special, fx: FX(externalPlugins: [Plugin(id: "special")]))
    let show = ShowController([a, Track(id: UUID()), ignored, b], master: FX(externalPlugins: [Plugin(id: "masterFX")]))
    show.snapshot.project.songs.append(Song(tracks: [Track(id: UUID(), fx: FX(externalPlugins: [Plugin(id: "other-song")]))]))
    try! ExternalPluginState.captureAllForSaving(show: show)
    precondition(show.captures == ["master:masterFX", a.id.uuidString + ":a1", a.id.uuidString + ":a2", b.id.uuidString + ":b"])
    precondition(show.searches == 0 && show.clips == 1)
    precondition(show.snapshot.project.masterFX!.externalPlugins![0].state == 1)
    precondition(show.snapshot.project.songs[0].tracks[0].fx!.externalPlugins!.allSatisfy { $0.state == 1 },
                 "each capture preserves the live state captured for previous plugins")
    try! ExternalPluginState.captureAllForSaving(show: show)
    precondition(show.snapshot.project.songs[0].tracks[0].fx!.externalPlugins!.allSatisfy { $0.state == 2 })

    let failure = ShowController([a, b], master: FX(externalPlugins: [Plugin(id: "masterFX")]))
    failure.rejected = "a2"
    do { try ExternalPluginState.captureAllForSaving(show: failure); preconditionFailure("capture failure must abort Save") }
    catch CaptureFailure.rejected {}
    catch { preconditionFailure("unexpected error") }
    precondition(failure.captures == ["master:masterFX", a.id.uuidString + ":a1"] && failure.clips == 0)
    let clipFailure = ShowController()
    clipFailure.rejected = "clip"
    do { try ExternalPluginState.captureAllForSaving(show: clipFailure); preconditionFailure("take capture failure must abort Save") }
    catch CaptureFailure.rejected {}
    catch { preconditionFailure("unexpected error") }
    let noSong = ShowController(master: FX(externalPlugins: [Plugin(id: "masterFX")]))
    noSong.currentSong = nil
    try! ExternalPluginState.captureAllForSaving(show: noSong)
    precondition(noSong.captures == ["master:masterFX"] && noSong.clips == 1)
}
print("PLUGIN_SAVE_LINEAR_TARGET_ENUMERATION_MASTER_TRACK_TAKES_LIVE_STATE_AND_FAILURES_OK")
