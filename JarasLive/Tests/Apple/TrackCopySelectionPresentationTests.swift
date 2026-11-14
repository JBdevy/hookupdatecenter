import AppKit
import SwiftUI
@testable import JarasApplication
// INSERT_PRODUCTION_MIXER_METADATA

@MainActor private final class CopyPresentationExecutor: CommandExecutor {
    var project = Project.empty(name: "Copy selection fixture")
    func load(_ value: Project) throws { try value.validate(); project = value }
    func snapshot() throws -> ShowSnapshot {
        ShowSnapshot(project: project, transport: TransportState(playing: false, songId: project.songs[0].id,
            position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    }
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: try snapshot().transport) }
    func applyProjectEdit(_ value: Project) throws { try value.validate(); project = value }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws {}
    func addTrack(id: UUID, name: String, role: TrackRole) throws {}
    func advance(_ elapsed: Double) {}
    func finishCurrentSong(_ enabled: Bool) {}
}

private final class SelectionView: NSView {
    var selected = Set<UUID>()
    var anchor: UUID?
    var select: (UUID) -> Void = { _ in }
}
private struct SelectionProbe: NSViewRepresentable {
    let selection: Set<UUID>, anchor: UUID?
    let select: (UUID) -> Void
    func makeNSView(context: Context) -> SelectionView { SelectionView() }
    func updateNSView(_ view: SelectionView, context: Context) {
        view.selected = selection; view.anchor = anchor; view.select = select
    }
}
private struct GridSelectionFixture: View {
    let show: ShowController
    @StateObject private var updates: ShowTimelinePresentationObserver
    init(show: ShowController) {
        self.show = show
        _updates = StateObject(wrappedValue: ShowTimelinePresentationObserver(show: show))
    }
    // INSERT_PRODUCTION_SELECTION
    var body: some View {
        let _ = updates.state
        SelectionProbe(selection: selectedTracks, anchor: selectedTrack, select: { id in
            selectedTrack = id; selectedTracks = [id]
        })
    }
}
private struct HozSelectionFixture: View {
    let show: ShowController
    @ObservedObject var updates: ShowProjectPresentation
    var body: some View {
        SelectionProbe(selection: show.mixerTrackSelection, anchor: show.selectedTrackForActions,
            select: { show.setMixerTrackSelection([$0], anchor: $0) })
    }
}
private func selectionViews(_ view: NSView) -> [SelectionView] {
    ((view as? SelectionView).map { [$0] } ?? []) + view.subviews.flatMap(selectionViews)
}

setbuf(stdout, nil)
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
Task { @MainActor in
    do {
        let executor = CopyPresentationExecutor()
        var tempoSong = executor.project.songs[0]
        tempoSong.bpm = 120
        tempoSong.tracks = (0..<120).map { index in
            var track = Track(id: UUID(), name: "Track \(index)", role: .other)
            track.clips = [AudioClip(id: UUID(), name: "Audio", startTime: 0, duration: 60)]
            return track
        }
        let mixerRevision = TimelineMixerContentRevision()
        @MainActor func controlsVersion(_ song: Song, directory: URL? = nil) -> UInt64 {
            mixerRevision.update(tracks: song.tracks, project: executor.project.id, song: song.id, directory: directory)
        }
        let originalControls = controlsVersion(tempoSong)
        tempoSong.followTempo(150)
        precondition(controlsVersion(tempoSong) == originalControls,
                     "Retiming 120 tracks must not replace unchanged mixer controls")
        tempoSong.tracks[0].mute = true
        let mutedControls = controlsVersion(tempoSong)
        precondition(mutedControls != originalControls, "Real mixer changes must still refresh controls")
        tempoSong.tracks.swapAt(0, 1)
        let reorderedControls = controlsVersion(tempoSong)
        precondition(reorderedControls != mutedControls, "Reordering must refresh track numbers and targets")
        precondition(controlsVersion(tempoSong, directory: URL(fileURLWithPath: "/tmp/new-project")) != reorderedControls,
                     "Changing project location must refresh media actions")
        print("BPM_120_TRACKS_RETAINS_MIXER_ROOT_AND_CONTROL_EDITS_REFRESH_OK")
        let source = Track(id: UUID(), name: "Source", role: .other)
        executor.project.songs[0].tracks = [source]
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: executor.project)
        let immediateTimeline = ShowTimelinePresentationObserver(show: show)
        let window = NSPanel(contentRect: CGRect(x: -10000, y: -10000, width: 300, height: 300),
                             styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: VStack {
            GridSelectionFixture(show: show)
            HozSelectionFixture(show: show, updates: show.projectPresentation)
        })
        if #available(macOS 13, *) { host.sizingOptions = [] }
        window.contentView = host; window.orderBack(nil)
        @MainActor func flush() async throws {
            try await Task.sleep(nanoseconds: 20_000_000)
            host.layoutSubtreeIfNeeded()
        }
        try await flush()
        let views = selectionViews(host)
        precondition(views.count == 2)
        views[0].select(source.id)
        precondition(immediateTimeline.state.trackSelection == [source.id],
                     "Track Mixer must publish the committed click in the same display pass as Hoz-Mixer")
        try await flush()
        precondition(show.copyTracks([source.id]))
        var newest = source.id
        for index in 0..<200 {
            let ids = show.pasteTracks()
            newest = show.current!.tracks.last!.id
            precondition(ids == [newest])
            // Exercise coalesced key repeats, with several insertions between
            // SwiftUI display passes, as well as ordinary individual presses.
            if index % 4 == 0 { try await flush() }
        }
        try await flush()
        precondition(views.allSatisfy { $0.selected == [newest] && $0.anchor == newest },
                     "Both retained hosts must display the newest copy after repeated Paste")
        views[1].select(source.id)
        precondition(immediateTimeline.state.trackSelection == [source.id],
                     "A Hoz click must immediately invalidate the Track Mixer too")
        try await flush()
        precondition(views.allSatisfy { $0.selected == [source.id] }, "A click in either mixer must update both selections")
        views[0].select(newest)
        precondition(immediateTimeline.state.trackSelection == [newest])
        try await flush()
        precondition(views.allSatisfy { $0.selected == [newest] })
        let added = show.addTracks(name: "New", role: .other, count: 3)
        try await flush()
        precondition(added.count == 3 && views.allSatisfy { $0.selected == [added.last!] })
        window.orderOut(nil); window.contentView = nil; window.close()
        print("COPY_SELECTION_200_REPEATS_SHARED_GRID_HOZ_PRESENTATION_AND_NEW_TRACKS_OK")
        exit(0)
    } catch { print(error); exit(1) }
}
RunLoop.main.run()
