import AppKit
import SwiftUI
@testable import JarasApplication

private enum JarasTheme {
    static let secondary = Color.gray
    static let background = Color.black
}
private enum JarasLocalization { static func string(_ value: String) -> String { value } }
private extension Font {
    static let jarasHeadline = Font.headline
    static let jarasCaption = Font.caption
}
private final class SubplaySelectionProbeView: NSView {
    var selection = Set<UUID>()
    var update: (Set<UUID>) -> Void = { _ in }
    var apply: () -> Void = {}
    var cancel: () -> Void = {}
}
private struct SubplaySelectionProbe: NSViewRepresentable {
    @Binding var selection: Set<UUID>
    let apply: () -> Void
    let cancel: () -> Void
    func makeNSView(context: Context) -> SubplaySelectionProbeView { SubplaySelectionProbeView() }
    func updateNSView(_ view: SubplaySelectionProbeView, context: Context) {
        view.selection = selection; view.update = { selection = $0 }; view.apply = apply; view.cancel = cancel
    }
}
private func probes(_ view: NSView) -> [SubplaySelectionProbeView] {
    (view as? SubplaySelectionProbeView).map { [$0] } ?? view.subviews.flatMap(probes)
}
@MainActor private func run() throws {
    _ = NSApplication.shared
    var project = Project.empty(name: "Saved Subplay")
    project.songs[0].tracks = [Track(id: UUID(), name: "CLICK", role: .other),
        Track(id: UUID(), name: "REGENCIA", role: .other), Track(id: UUID(), name: "GUITARRA", role: .other)]
    let tracks = project.songs[0].tracks
    var setlist = RegionSetlist()
    setlist.subplayExclusiveTrackIDs = [tracks[0].id, tracks[1].id]
    project.regionSetlist = setlist
    let restored = try ProjectDocumentCodec.decode(ProjectDocumentCodec.encode(project))
    let saved = Set(restored.regionSetlist!.subplayExclusiveTrackIDs!)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 440), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // Render offscreen without activating this fixture or the user's app.
    let host = NSHostingView(rootView: AnyView(Color.clear))
    window.contentView = host
    defer { window.close() }
    var applied: Set<UUID>?, canceled = false
    func settle() {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.04))
        host.layoutSubtreeIfNeeded()
    }
    func open(_ selection: Set<UUID>) {
        let request = SubplayTrackSelectionRequest(tracks: restored.songs[0].tracks, selected: selection)
        host.rootView = AnyView(SubplayTrackSelectionEditor(request: request, cancel: { canceled = true }) { applied = $0 }.id(request.id))
        settle()
    }
    func probe() -> SubplaySelectionProbeView { probes(host).first! }
    func selected(_ name: String) -> Bool { probe().selection.contains(tracks.first { $0.name == name }!.id) }
    for _ in 0..<3 {
        open(saved)
        precondition(selected("CLICK") && selected("REGENCIA") && !selected("GUITARRA"), "First opening must show the persisted selection")
        probe().update(saved.subtracting([tracks[0].id]))
        settle()
        precondition(!selected("CLICK") && selected("REGENCIA"), "Editing the chooser must update its local draft")
        probe().cancel()
        precondition(canceled && applied == nil, "Cancel must not overwrite the saved selection")
    }
    open(saved)
    probe().apply()
    precondition(applied == saved, "Apply without rechecking must retain both persisted tracks")
    open([])
    precondition(!selected("CLICK") && !selected("REGENCIA"), "An empty selection must not inherit another opening's state")
    open([tracks[2].id])
    precondition(!selected("CLICK") && !selected("REGENCIA") && selected("GUITARRA"), "A different project/selection must initialize from its own values")
    print("SUBPLAY_SAVED_SELECTION_FIRST_OPEN_CANCEL_REOPEN_APPLY_AND_REPLACEMENT_OK")
}
try MainActor.assumeIsolated { try run() }
