import AppKit
import SwiftUI
@testable import JarasApplication

// Display-only dependencies of the two extracted production views. Their
// subscriptions, controls, local drafts and presentation-ID handling are real.
@MainActor final class ProjectDocuments { var canCleanTimelineMedia = false }
enum JarasTheme {
    static let background = Color.black, panel = Color.gray, text = Color.white, secondary = Color.gray, green = Color.green
}
extension Font {
    static let jarasHeadline = Font.headline, jarasTitle3 = Font.title3, jarasCaption = Font.caption
    static func jarasSystem(size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
}
struct InputValidationShake: GeometryEffect {
    var animatableData: Double
    func effectValue(size: CGSize) -> ProjectionTransform { ProjectionTransform(.identity) }
}
struct AdvancedTransportSettings: View { var body: some View { Text("Transport") } }
struct AdvancedVideoSettings: View { var body: some View { Text("Video") } }
struct AdvancedPadsSettings: View { var body: some View { Text("Pads") } }
struct AdvancedSetlistColors: View { var body: some View { Text("Setlist") } }
struct AdvancedKeyboardSettings: View { var body: some View { Text("Keyboard") } }
struct MediaProcessingFormatEditor: View { let scope: String; var body: some View { Text(scope) } }
struct TimelineMediaCleanupConfirmation: View { let documents: ProjectDocuments; var body: some View { Text("Cleanup") } }
enum TimelineAppearanceDefaults {
    static let background: UInt32 = 0, primaryGrid: UInt32 = 1, secondaryGrid: UInt32 = 2
    static let playCursor: UInt32 = 3, editCursor: UInt32 = 4, subPlayCursor: UInt32 = 5
}
struct SetlistTextColorRow: View {
    let title: String, key: String, defaultColor: UInt32, showsReset: Bool
    var body: some View { HStack { Text(title); Button("Reset") {} } }
}

@MainActor enum AdvancedPresentationProbe {
    static var root = 0, timeline = 0, draft = ""
    static var observedColor: UInt32?
    static var editDraft: (String) -> Void = { _ in }, selectTimeline: () -> Void = {}
}

@MainActor final class AdvancedPresentationExecutor: CommandExecutor {
    var project = Project.empty(name: "Advanced presentation fixture")
    var transport = TransportState(playing: true, position: 0, queue: QueueState(),
        loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0))
    func load(_ project: Project) throws { self.project = project; transport.songId = project.songs[0].id }
    func snapshot() throws -> ShowSnapshot { ShowSnapshot(project: project, transport: transport) }
    func playbackSnapshot() throws -> PlaybackSnapshot { PlaybackSnapshot(transport: transport) }
    func advance(_ elapsed: Double) { transport.position += 1.0 / 30 }
    func execute(_ command: ShowCommand, target: UUID?, value: Double) throws {}
    func addTrack(id: UUID, name: String, role: TrackRole) throws {}
    func finishCurrentSong(_ enabled: Bool) {}
    func editMasterColor(_ color: UInt32) throws { project.masterColor = color }
}

// INSERT_PRODUCTION_VIEWS

setbuf(stdout, nil)
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
Task { @MainActor in
    do {
        _ = NSApplication.shared
        let baseline = CommandLine.arguments.contains("--baseline")
        let executor = AdvancedPresentationExecutor()
        let show = try ShowController(executor: executor, persistence: MemoryProjectStore(), initialProject: executor.project)
        let window = NSPanel(contentRect: CGRect(origin: CGPoint(x: -10000, y: -10000), size: AdvancedView.desktopSize),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AdvancedView(show: show))
        if #available(macOS 13, *) { host.sizingOptions = [] }
        window.contentView = host; window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        @MainActor func flush() async throws { try await Task.sleep(nanoseconds: 20_000_000); host.layoutSubtreeIfNeeded() }
        try await flush()
        AdvancedPresentationProbe.editDraft("137.25")
        AdvancedPresentationProbe.selectTimeline()
        try await flush()
        precondition(AdvancedPresentationProbe.timeline > 0 && AdvancedPresentationProbe.draft == "137.25")

        for hidden in [false, true] {
            host.isHidden = hidden
            if hidden { window.orderOut(nil) } else { window.orderBack(nil) }
            try await flush()
            let before = (AdvancedPresentationProbe.root, AdvancedPresentationProbe.timeline)
            for _ in 0..<30 { show.tick(); try await flush() }
            let root = AdvancedPresentationProbe.root - before.0, timeline = AdvancedPresentationProbe.timeline - before.1
            print("ADVANCED_PLAYBACK hidden=\(hidden) baseline=\(baseline) root_evaluations=\(root) timeline_evaluations=\(timeline)")
            if !baseline { precondition(root == 0 && timeline == 0, "Position ticks must not rebuild retained Advanced controls") }
            else if !hidden { precondition(root > 20 && timeline > 20, "The old observer must reproduce repeated evaluations") }
            precondition(AdvancedPresentationProbe.draft == "137.25", "Playback must preserve unfinished text")
        }
        let beforeEdit = AdvancedPresentationProbe.root
        show.editMasterColor(0x123456)
        try await flush()
        host.isHidden = false; window.orderBack(nil); try await flush()
        precondition(AdvancedPresentationProbe.root > beforeEdit && AdvancedPresentationProbe.observedColor == 0x123456,
                     "A hidden editor must still show committed project changes when revealed")
        precondition(AdvancedPresentationProbe.draft == "137.25", "Unrelated project edits must preserve the timing draft")
        let timelineBeforeReopen = AdvancedPresentationProbe.timeline
        host.rootView = AdvancedView(show: show, presentationID: 1)
        try await flush(); try await flush()
        precondition(AdvancedPresentationProbe.draft == String(format: "%g", show.current!.bpm),
                     "The existing presentation-ID rule must refresh timing on explicit reopen")
        precondition(AdvancedPresentationProbe.timeline > timelineBeforeReopen,
                     "Reopening must retain the selected Timeline tab")
        print("ADVANCED_VISIBLE_HIDDEN_TICKS_PROJECT_UPDATES_DRAFT_AND_REOPEN_OK")
        exit(0)
    } catch { print("ADVANCED_PRESENTATION_ERROR", error); exit(1) }
}
NSApp.run()
