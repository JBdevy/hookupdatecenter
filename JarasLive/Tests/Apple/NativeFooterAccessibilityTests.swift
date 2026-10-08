// Included in the production extraction fixture by test-footer-display-resize.sh.
private enum FooterAXJournal {
    static weak var root: NSView?
    static var fx: [Int] = [], edits: [Int] = []
    static var audio = 0, roots = 0
    static var assignments = 0
    static var finished = false
    static var font: String?
}
private final class FooterAXState: ObservableObject { @Published var revision = 0 }
private struct FooterAXActions: View {
    @Environment(\.openFX) private var openFX
    @Environment(\.editTrackDetails) private var editTrackDetails
    @Environment(\.locale) private var locale
    @Environment(\.font) private var font
    var body: some View {
        let _ = { FooterAXJournal.font = String(describing: font) }()
        HStack {
            Text("Native Locale \(locale.identifier)")
            Button("FX") { openFX(nil, "EQ") }.accessibilityLabel("Native FX")
            Button("Edit track") {
                editTrackDetails(TrackDetailsEditRequest(project: UUID(), tracks: [], name: "Track", color: 0, nameEditable: true))
            }.accessibilityLabel("Native Edit track")
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
private struct FooterAXDisplay: View {
    let label: String
    let show = ShowController()
    var body: some View {
        HStack {
            Text("CPU 1%").accessibilityLabel("\(label) CPU").fixedSize()
            FooterPlaylistDisplay(show: show, scalesToAvailableHeight: true)
            Button("Audio Settings") { FooterAXJournal.audio += 1 }.accessibilityLabel("\(label) Audio Settings")
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
private struct FooterAXFixture: View {
    @ObservedObject var state: FooterAXState
    let coordinator = FooterVerticalResizeCoordinator()
    var body: some View {
        let _ = { FooterAXJournal.roots += 1 }()
        let revision = state.revision
        VStack(spacing: 0) {
            FooterAXDisplay(label: "Baseline").frame(height: 27)
            Spacer()
            HStack {
                Button("Refresh callbacks") { state.revision += 1 }
                Button("Prepare resize") { prepareFooterAXResize() }
                Button("Verify and close") { verifyFooterAXFixture() }
            }.frame(height: 32)
            FooterNativeHeightHost(storedHeight: 232, minimum: 232, maximum: 723.55859375, active: true,
                identity: "ax-mixer", role: .mixer, resizeCoordinator: coordinator) {
                VStack(spacing: 0) {
                    FooterMixerResizeInput(height: 232, maximum: 723.55859375, changed: { _ in }, ended: { _ in }).frame(height: 8)
                    FooterAXActions()
                }
            }
            FooterNativeHeightHost(storedHeight: 27, minimum: 27, maximum: 161.046875, active: true,
                identity: "ax-display", role: .display, resizeCoordinator: coordinator,
                displayAvailableHeight: 850, fallbackMixerHeight: 232) {
                FooterAXDisplay(label: "Native").overlay(FooterDisplayResizeInput(height: 27, maximum: 161.046875,
                    changed: { _ in }, ended: { _ in }))
            }
        }.environment(\.locale, Locale(identifier: "pt_BR")).font(.system(size: 17))
            .environment(\.openFX, { _, _ in FooterAXJournal.fx.append(revision) })
            .environment(\.editTrackDetails, { _ in FooterAXJournal.edits.append(revision) })
    }
}
@MainActor private func prepareFooterAXResize() {
    let root = FooterAXJournal.root!
    let hosts = descendants(FooterHeightContainerView.self, in: root)
    let assignments = hosts.reduce(0) { $0 + $1.contentAssignments }
    expect(assignments == FooterAXJournal.assignments, "new editor callbacks must not replace nested SwiftUI roots")
    let roots = FooterAXJournal.roots
    let identities = Set(descendants(FooterVerticalResizeView.self, in: root).map(ObjectIdentifier.init))
    for handle in descendants(FooterVerticalResizeView.self, in: root) {
        let y = handle.convert(NSPoint(x: 10, y: handle.bounds.midY), to: nil).y
        func event(_ type: NSEvent.EventType, _ delta: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: 200, y: y + delta), modifierFlags: [], timestamp: 1,
                windowNumber: root.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        handle.mouseDown(with: event(.leftMouseDown, 0))
        handle.mouseDragged(with: event(.leftMouseDragged, 60))
        handle.mouseUp(with: event(.leftMouseUp, 60))
    }
    expect(FooterAXJournal.roots == roots && hosts.reduce(0) { $0 + $1.contentAssignments } == assignments,
        "accessibility must survive resize without outer evaluations or root replacements")
    expect(Set(descendants(FooterVerticalResizeView.self, in: root).map(ObjectIdentifier.init)) == identities,
        "accessibility resizing must preserve native input identities")
}
@MainActor private func verifyFooterAXFixture() {
    expect(FooterAXJournal.fx == [0, 1] && FooterAXJournal.edits == [0, 1], "AX actions must use refreshed editor callbacks")
    expect(FooterAXJournal.audio == 1, "AX press must reach the hosted audio settings action")
    expect(FooterJournal.fontScales.contains { $0 > 1.5 }, "production display fonts must still grow after AX-triggered resize")
    expect(FooterAXJournal.font == String(describing: Optional(Font.system(size: 17))), "nested hosting must retain its inherited font")
    FooterAXJournal.finished = true
}
@MainActor private func runFooterAccessibilityFixture() {
    let state = FooterAXState()
    let root = NSHostingView(rootView: FooterAXFixture(state: state)); FooterAXJournal.root = root
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1200, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
    window.title = "CatLive Footer AX Test"; window.isReleasedWhenClosed = false; window.contentView = root; window.orderFront(nil)
    defer { window.orderOut(nil); window.close() }
    root.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.15)); root.layoutSubtreeIfNeeded()
    FooterAXJournal.assignments = descendants(FooterHeightContainerView.self, in: root).reduce(0) { $0 + $1.contentAssignments }
    let deadline = Date().addingTimeInterval(12)
    while !FooterAXJournal.finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    expect(FooterAXJournal.finished, "external accessibility driver did not finish")
    print("FOOTER_EXTERNAL_AX_ACTIONS_LOCALE_FONT_CALLBACK_REFRESH_ROOTS_AND_RESIZE_OK")
}
