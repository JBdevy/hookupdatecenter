// Included after the real TrackPanFader/TrackVolumeFader and native sliders by
// scripts/test-master-control-project-identity.sh. No production callback is replaced.
private enum AutomationTarget { enum Kind { case pan, volume } }
private enum ShowCommand { case pan, volume }
private struct TestProject { var id = UUID(); var masterPan = 0.0; var masterVolume = 1.0 }
private struct TestSnapshot { var project = TestProject() }
private struct TestTrack { let id: UUID; var stereoLink: TestLink? }
private struct TestLink { let partner: UUID }
private struct TestSong { var tracks: [TestTrack] = [] }
@MainActor private final class ShowProjectPresentation: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
}
@MainActor private final class ShowController: ObservableObject {
    struct Command {
        let project: UUID
        let kind: ShowCommand
        let value: Double
        let preview: Bool
    }
    var projectSessionID = UUID()
    let projectPresentation = ShowProjectPresentation()
    @Published var snapshot = TestSnapshot() {
        didSet { projectPresentation.objectWillChange.send() }
    }
    let mixerPreviewValues: [UUID: Double] = [:]
    var current: TestSong? { TestSong() }
    private(set) var commands: [Command] = []
    func automationPlaybackValue(_ track: UUID?, kind: AutomationTarget.Kind) -> Double? { nil }
    func sendMixerControl(_ command: ShowCommand, target: UUID?, value: Double = 0, preview: Bool = false) {
        precondition(target == nil, "This fixture exercises the Master")
        commands.append(Command(project: snapshot.project.id, kind: command, value: value, preview: preview))
        if !preview {
            if command == .pan { snapshot.project.masterPan = value }
            else { snapshot.project.masterVolume = value }
        }
    }
}
private enum JarasTheme { static let green = Color.green; static let yellow = Color.yellow; static let text = Color.white }
private struct MappingRightClick: ViewModifier {
    let track: UUID?; let command: String; var hitHeight: CGFloat = 16
    func body(content: Content) -> some View { content }
}
private struct PhaseInvertButton: View {
    let show: ShowController; let track: UUID; let inverted: Bool
    var body: some View { EmptyView() }
}
private extension View { func jarasHelp(_ text: String) -> some View { self } }

@MainActor private struct MasterControlsFixture: View {
    let show: ShowController
    @ObservedObject private var updates: ShowProjectPresentation
    init(show: ShowController) {
        self.show = show
        _updates = ObservedObject(wrappedValue: show.projectPresentation)
    }
    var body: some View {
        VStack(spacing: 12) {
            TrackPanFader(show: show, track: nil, pan: show.snapshot.project.masterPan, compact: true)
                .frame(width: 120, height: 28)
            TrackVolumeFader(show: show, track: nil, volume: show.snapshot.project.masterVolume,
                             phaseInverted: false, compact: true)
                .frame(width: 260, height: 24)
        }.frame(width: 300, height: 100).id(show.projectSessionID)
    }
}
@MainActor private final class MasterControlsWindow {
    let show = ShowController()
    let window: NSWindow
    let host: NSHostingView<MasterControlsFixture>
    init() {
        host = NSHostingView(rootView: MasterControlsFixture(show: show))
        if #available(macOS 13, *) { host.sizingOptions = [] }
        if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
        window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 300, height: 100),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        settle()
    }
    func settle() {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        host.layoutSubtreeIfNeeded()
    }
    func sliders() -> [DirectVolumeSliderView] {
        func collect(_ view: NSView) -> [DirectVolumeSliderView] {
            (view as? DirectVolumeSliderView).map { [$0] } ?? view.subviews.flatMap(collect)
        }
        return collect(host)
    }
    func event(_ type: NSEvent.EventType, _ slider: DirectVolumeSliderView, fraction: CGFloat, clickCount: Int = 1) -> NSEvent {
        let point = slider.convert(NSPoint(x: slider.bounds.width * fraction, y: slider.bounds.midY), to: nil)
        return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clickCount, pressure: 1)!
    }
    func doubleClick(_ slider: DirectVolumeSliderView) {
        slider.mouseDown(with: event(.leftMouseDown, slider, fraction: 0.5, clickCount: 2))
        slider.mouseUp(with: event(.leftMouseUp, slider, fraction: 0.5, clickCount: 2))
        settle()
    }
    func click(_ slider: DirectVolumeSliderView, fraction: CGFloat) {
        slider.mouseDown(with: event(.leftMouseDown, slider, fraction: fraction))
        slider.mouseUp(with: event(.leftMouseUp, slider, fraction: fraction))
        settle()
    }
}

@MainActor private func runMasterProjectIdentityTests() {
    _ = NSApplication.shared
    var failures: [String] = []
    func expect(_ value: Bool, _ reason: String) {
        if !value { failures.append(reason); print("FAIL: \(reason)") }
    }
    // Master values often remain 0 dB / Center when opening another document.
    // The parent redraws, but wrappers with only unchanged reference/scalar
    // inputs can retain the previous project's captured command identity.
    do {
        let fixture = MasterControlsWindow()
        defer { fixture.window.close() }
        let original = fixture.show.snapshot.project.id
        let initialSliders = fixture.sliders()
        expect(initialSliders.count == 2, "Both real Master controls must be mounted")
        expect(initialSliders.allSatisfy { $0.boundProject == original }, "Initial project binding")
        fixture.show.snapshot = TestSnapshot()
        let replacement = fixture.show.snapshot.project.id
        fixture.settle()
        let sliders = fixture.sliders()
        expect(sliders.allSatisfy { $0.boundProject == replacement }, "Equal-value project switch must rebind both Master controls")
        for slider in sliders {
            let command = slider.mini ? ShowCommand.pan : .volume
            let before = fixture.show.commands.count
            fixture.click(slider, fraction: 0.3)
            let calls = Array(fixture.show.commands.dropFirst(before))
            expect(calls.contains { $0.project == replacement && $0.kind == command && $0.preview },
                   "New project's \(command) gesture must deliver preview")
            expect(calls.contains { $0.project == replacement && $0.kind == command && !$0.preview },
                   "New project's \(command) gesture must commit")
        }
    }
    // Complete a gesture first so SwiftUI state is already materialized, reset
    // both controls using the real native double-click path, and then open a
    // project with the exact same scalar values. This is the normal Master
    // workflow, without requiring a document change while dragging.
    do {
        let fixture = MasterControlsWindow()
        defer { fixture.window.close() }
        for slider in fixture.sliders() {
            let command = slider.mini ? ShowCommand.pan : .volume
            slider.mouseDown(with: fixture.event(.leftMouseDown, slider, fraction: 0.2))
            slider.mouseDragged(with: fixture.event(.leftMouseDragged, slider, fraction: 0.7))
            slider.mouseUp(with: fixture.event(.leftMouseUp, slider, fraction: 0.7))
            fixture.settle()
            expect(fixture.show.commands.contains { $0.kind == command && !$0.preview },
                   "Completed initial \(command) drag must commit")
            fixture.doubleClick(slider)
            let reset = slider.mini ? fixture.show.snapshot.project.masterPan : fixture.show.snapshot.project.masterVolume
            expect(abs(reset - (slider.mini ? 0 : 1)) < 1e-10,
                   "Native double-click must reset \(command) before switching")
        }
        expect(fixture.sliders().allSatisfy { !$0.trackingPointer }, "All previous gestures must be finished")
        fixture.show.snapshot = TestSnapshot()
        let replacement = fixture.show.snapshot.project.id
        fixture.settle()
        for slider in fixture.sliders() {
            let command = slider.mini ? ShowCommand.pan : .volume
            expect(slider.boundProject == replacement, "Used \(command) must rebind on equal-value project switch")
            let before = fixture.show.commands.count
            fixture.click(slider, fraction: 0.3)
            let calls = Array(fixture.show.commands.dropFirst(before))
            expect(calls.contains { $0.project == replacement && $0.kind == command && $0.preview },
                   "Used \(command) must preview after project switch")
            expect(calls.contains { $0.project == replacement && $0.kind == command && !$0.preview },
                   "Used \(command) must commit after project switch")
            fixture.doubleClick(slider)
            let reset = slider.mini ? fixture.show.snapshot.project.masterPan : fixture.show.snapshot.project.masterVolume
            expect(abs(reset - (slider.mini ? 0 : 1)) < 1e-10,
                   "Native double-click must reset \(command) in replacement project")
        }
    }
    // A document switch during a drag must drop the old completion, then
    // accept new gestures without replaying old values into the replacement.
    for pan in [true, false] {
        let fixture = MasterControlsWindow()
        defer { fixture.window.close() }
        guard let slider = fixture.sliders().first(where: { $0.mini == pan }) else {
            expect(false, "Missing native slider"); continue
        }
        slider.mouseDown(with: fixture.event(.leftMouseDown, slider, fraction: 0.2))
        slider.mouseDragged(with: fixture.event(.leftMouseDragged, slider, fraction: 0.7))
        fixture.settle()
        expect(fixture.show.commands.contains { $0.preview }, "Initial active drag must reach backend")
        let beforeSwap = fixture.show.commands.count
        fixture.show.snapshot = TestSnapshot()
        let replacement = fixture.show.snapshot.project.id
        fixture.settle()
        slider.mouseUp(with: fixture.event(.leftMouseUp, slider, fraction: 0.7))
        fixture.settle()
        expect(fixture.show.commands.count == beforeSwap, "Old drag completion must not modify the replacement project")
        let current = fixture.sliders().first { $0.mini == pan }!
        expect(current.boundProject == replacement && !current.trackingPointer, "Active drag must finish and rebind on project switch")
        let beforeNewGesture = fixture.show.commands.count
        fixture.click(current, fraction: 0.4)
        let calls = Array(fixture.show.commands.dropFirst(beforeNewGesture))
        expect(calls.contains { $0.project == replacement && !$0.preview }, "Fresh gesture after switched active drag must commit")
    }
    // A backup can carry exactly the same project and track UUIDs. Replacing
    // the workspace releases its native views; their delayed mouse-up must
    // never write the old pointer value into the new session.
    for pan in [true, false] {
        let fixture = MasterControlsWindow()
        defer { fixture.window.close() }
        let oldSlider = fixture.sliders().first { $0.mini == pan }!
        oldSlider.mouseDown(with: fixture.event(.leftMouseDown, oldSlider, fraction: 0.25))
        fixture.settle()
        let before = fixture.show.commands.count
        let sameProject = fixture.show.snapshot.project
        fixture.show.projectSessionID = UUID()
        fixture.show.snapshot = TestSnapshot(project: sameProject)
        fixture.settle()
        oldSlider.mouseUp(with: fixture.event(.leftMouseUp, oldSlider, fraction: 0.25))
        fixture.settle()
        expect(fixture.show.commands.count == before, "A copied project's old gesture must never commit during workspace teardown")
        let freshSlider = fixture.sliders().first { $0.mini == pan }!
        expect(freshSlider !== oldSlider && freshSlider.boundSession == fixture.show.projectSessionID,
               "A same-UUID document must start with a newly bound native control")
        fixture.click(freshSlider, fraction: 0.4)
        expect(fixture.show.commands.dropFirst(before).contains { !$0.preview }, "New same-UUID session must accept fader/pan commands")
    }
    if !failures.isEmpty { print("MASTER_CONTROL_PROJECT_IDENTITY_FAILED count=\(failures.count)"); exit(1) }
    print("MASTER_CONTROL_PROJECT_IDENTITY_EQUAL_VALUES_COMPLETED_DRAG_DOUBLE_CLICK_AND_ACTIVE_DRAG_OK")
}
MainActor.assumeIsolated { runMasterProjectIdentityTests() }
