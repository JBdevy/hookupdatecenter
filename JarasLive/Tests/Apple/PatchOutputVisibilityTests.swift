// Uses the real PatchEditor and window sizing function extracted by the runner.
// The model is isolated from audio devices and users' open projects.
private struct ProjectError: Error { static func invalid(_ message: String) -> Self { Self() } }
private struct Track: Identifiable {
    var id = UUID(), name = "Test track"
    var role = Role(), kind = Kind.standard, outputPatches: [OutputPatch] = [.master]
    var parentTrackID: UUID?, inputPatch: OutputPatch?, stereoLink: Link?, midiInput: Int?, midiChannel: Int?, routing: Routing?
    struct Role { var rawValue = "audio" }; enum Kind { case standard, timecode, click }
    struct Link { var left: Bool }; struct Routing { var receives: [UUID?] = [], transmitters: [UUID?] = [] }
}
private struct Song { var tracks = [Track()] }
private struct Project { var songs = [Song()], masterOutputPatches: [OutputPatch] = [.stereo] }
private struct Snapshot { var project = Project() }
private final class ShowController: ObservableObject {
    @Published var snapshot = Snapshot()
    var current: Song? { snapshot.project.songs.first }
    func setOutputPatches(track: UUID?, patches: [OutputPatch]) {
        if let track, let index = snapshot.project.songs[0].tracks.firstIndex(where: { $0.id == track }) {
            snapshot.project.songs[0].tracks[index].outputPatches = patches
        } else { snapshot.project.masterOutputPatches = patches }
    }
    func setMIDIChannel(_ id: UUID, channel: Int) {}
    func setRecordingInput(_ id: UUID, input: OutputPatch) {}
    func setMIDIInput(_ id: UUID, slot: Int) {}
    func addTrackRoute(_ tracks: Set<UUID>, receive: Bool) {}
    func setTrackRouting(_ tracks: Set<UUID>, receive: Bool, slot: Int, other: UUID?) {}
    func removeTrackRoute(_ tracks: Set<UUID>, receive: Bool, slot: Int) {}
}
private final class AudioDeviceSettings: ObservableObject {
    static let shared = AudioDeviceSettings()
    var channels = 2, deviceName = "Fixture device"
    func midiSlotTitle(_ slot: Int) -> String { "MIDI \(slot + 1)" }
}
private final class TrackRecording {
    static let shared = TrackRecording()
    var defaultInputPatch = OutputPatch.stereo, inputChannels = 2, recording = false
}
private struct TimecodeOptions: View { let show: ShowController; let track: Track; var body: some View { EmptyView() } }
private struct BatchPatchEditor: View { let show: ShowController; let targets: [UUID]; var body: some View { EmptyView() } }
private enum JarasTheme { static let secondary = Color.gray, text = Color.white }
private enum JarasLocalization { static func string(_ text: String) -> String { text } }
private extension Font { static var jarasHeadline: Font { .headline }; static var jarasCaption: Font { .caption }; static var jarasSubheadline: Font { .subheadline } }

private enum PatchProbeKind: Equatable { case add, output(Int) }
private struct PatchProbe: NSViewRepresentable {
    let kind: PatchProbeKind
    func makeNSView(context: Context) -> PatchProbeView { PatchProbeView(kind: kind) }
    func updateNSView(_ view: PatchProbeView, context: Context) { view.kind = kind }
}
private final class PatchProbeView: NSView {
    var kind: PatchProbeKind
    init(kind: PatchProbeKind) { self.kind = kind; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
private func descendants<T: NSView>(_ view: NSView, of: T.Type) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: T.self) }
}
private func settle(_ host: NSView) { RunLoop.main.run(until: Date().addingTimeInterval(0.08)); host.layoutSubtreeIfNeeded() }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
private func verifyOutputs(master: Bool, compact: Bool) {
    let show = ShowController(), track = master ? nil : show.current!.tracks[0].id
    let content = VStack { PatchEditor(show: show, track: track, targets: [track]); Button("Close") {} }.padding(12)
    let initial = workspaceEditorContentSize(content)
    require(initial.width >= 340 && (master || initial.height > 280), "The scaled GeometryReader must not define editor fitting size")
    let host = NSHostingView(rootView: InterfaceScaleLayout(factor: 1, content: WorkspaceEditorViewport(content: content, scrolls: false)))
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 380, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    window.setContentSize(compact ? NSSize(width: 340, height: 280) : initial)
    window.orderBack(nil); settle(host)
    defer { window.close() }
    let scroll = descendants(host, of: NSScrollView.self).last!
    for expected in 2...10 {
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView); settle(host)
        let add = descendants(host, of: PatchProbeView.self).first { $0.kind == .add }!
        let point = add.convert(NSPoint(x: add.bounds.midX, y: add.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: Double(expected), windowNumber: window.windowNumber, context: nil, eventNumber: expected, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
        }
        settle(host)
        let outputs = master ? show.snapshot.project.masterOutputPatches : show.current!.tracks[0].outputPatches
        require(outputs.count == expected, "Add output did not create slot \(expected)")
        let last = descendants(host, of: PatchProbeView.self).first { $0.kind == .output(expected - 1) }!
        let frame = last.convert(last.bounds, to: scroll.contentView)
        require(scroll.contentView.bounds.insetBy(dx: -1, dy: -1).contains(frame) && host.bounds.insetBy(dx: -1, dy: -1).contains(last.convert(last.bounds, to: host)),
                "New output \(expected) is hidden below Patch viewport: row=\(frame), viewport=\(scroll.contentView.bounds)")
    }
    print("PATCH_ADDED_OUTPUTS_VISIBLE master=\(master) compact=\(compact)")
}
let application = NSApplication.shared
verifyOutputs(master: false, compact: false)
verifyOutputs(master: false, compact: true)
verifyOutputs(master: true, compact: true)
