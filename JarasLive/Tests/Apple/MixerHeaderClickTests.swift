@MainActor private final class HeaderClickState: ObservableObject {
    @Published var width: CGFloat = 300
    @Published var revision = 0
    @Published var options = false
    var clicks: [String] = []
    var rightClicks = 0
    var outsideClicks = 0
    let native = NativeTimelineMixerWidth()
}
private final class HeaderUnderlyingRightClick: RightClickTargetView {
    override var priority: Int { 10_000 }
}
private final class HeaderUnderlyingControl: NSView, NativeTimelineControlInput {
    static var contextClicks = 0
    private let context = HeaderUnderlyingRightClick()
    private lazy var registration = NativeTimelineControlInputRegistration(self)
    override init(frame: NSRect) {
        super.init(frame: frame)
        context.action = { Self.contextClicks += 1 }; addSubview(context)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); context.frame = bounds }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); registration.update(active: window != nil) }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); registration.update(active: window != nil) }
    func hitTestTimelineControl(atWindowPoint point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: nil)) ? self : nil
    }
}
private struct HeaderUnderlyingProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> HeaderUnderlyingControl { HeaderUnderlyingControl() }
    func updateNSView(_ view: HeaderUnderlyingControl, context: Context) {}
}
private struct HeaderClickFixture: View {
    @ObservedObject var state: HeaderClickState
    var body: some View {
        HeaderUnderlyingProbe().frame(width: 300).frame(maxWidth: .infinity, alignment: .leading).overlay(alignment: .topLeading) {
            NativeTimelineMixerOverlay(width: state.width, maximum: 500, minimum: 140, dividerWidth: 6,
                headerHeight: 40, liveWidth: state.native, onEnd: { state.width = $0 }) {
                HStack(spacing: 4) {
                    ForEach(["snap", "eye", "timebase", "lock", "add"], id: \.self) { name in
                        Button { state.clicks.append("\(name)-\(state.revision)") } label: {
                            Text(name).frame(width: 40, height: 24).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("header-\(name)")
                            .immediateRightClick { if name == "lock" { state.rightClicks += 1; state.options = true } }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 40).background(Color.black)
                    .popover(isPresented: $state.options) { Text("Lock options").frame(width: 140, height: 70) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.overlay(alignment: .topTrailing) {
            Button("Outside header") { state.outsideClicks += 1 }.buttonStyle(.plain).frame(width: 140, height: 40)
        }
    }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular); app.finishLaunching()
    let state = HeaderClickState()
    let root = NativeWorkspaceHostingView(rootView: HeaderClickFixture(state: state))
    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 900, height: 600),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = root
    window.makeKeyAndOrderFront(nil)
    root.layoutSubtreeIfNeeded()
    print("HEADER_FIRST_DISPLAY active=\(app.isActive) key=\(window.isKeyWindow) root=\(root.frame)")
    func outsideClick() {
        let point = root.convert(NSPoint(x: root.bounds.maxX - 70, y: 20), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        app.postEvent(event(.leftMouseUp), atStart: false); app.sendEvent(event(.leftMouseDown))
        if let up = app.nextEvent(matching: .leftMouseUp, until: Date(timeIntervalSinceNow: 0.01), inMode: .default, dequeue: true) { app.sendEvent(up) }
        settle(root)
    }
    outsideClick()
    print("HEADER_OUTSIDE_CLICK before_activation=\(state.outsideClicks) active=\(app.isActive) key=\(window.isKeyWindow)")
    app.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); settle(root)
    let activationDeadline = Date(timeIntervalSinceNow: 1)
    while Date() < activationDeadline {
        if let input = app.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.01), inMode: .default, dequeue: true) { app.sendEvent(input) }
    }
    outsideClick()
    print("HEADER_OUTSIDE_CLICK after_activation=\(state.outsideClicks) active=\(app.isActive) key=\(window.isKeyWindow)")
    func click(_ index: Int, right: Bool = false) {
        let header = descendants(NSView.self, in: root).first { $0.identifier?.rawValue == "mixer-pinned-header" }!
        let point = header.convert(NSPoint(x: 20 + index * 44, y: 20), to: nil)
        let hit = root.hitTest(root.superview?.convert(point, from: nil) ?? point)
        precondition(hit != nil && (hit === header || hit!.isDescendant(of: header)),
                     "Header must own its native button hit before any resize; got \(String(describing: hit))")
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        let up = event(right ? .rightMouseUp : .leftMouseUp)
        app.postEvent(up, atStart: false)
        app.sendEvent(event(right ? .rightMouseDown : .leftMouseDown))
        if let posted = app.nextEvent(matching: right ? .rightMouseUp : .leftMouseUp,
                until: Date(timeIntervalSinceNow: 0.01), inMode: .default, dequeue: true) { app.sendEvent(posted) }
        settle(root)
    }
    for index in 0..<5 { click(index) }
    precondition(state.clicks == ["snap-0", "eye-0", "timebase-0", "lock-0", "add-0"],
                 "All five SwiftUI header buttons must receive real mouse-down/up on first display: \(state.clicks)")
    click(3, right: true)
    precondition(state.rightClicks == 1 && state.options, "Right-click must open lock settings")
    precondition(HeaderUnderlyingControl.contextClicks == 0, "The hidden row's high-priority context target must not steal the lock click")
    state.options = false; settle(root)
    let header = descendants(NSView.self, in: root).first { $0.identifier?.rawValue == "mixer-pinned-header" }!
    let lockPoint = header.convert(NSPoint(x: 152, y: 20), to: nil)
    let sheet = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
    sheet.isReleasedWhenClosed = false
    window.beginSheet(sheet); settle(root)
    precondition(NativeTimelineOverlayInputRegistration.hit(in: root, point: lockPoint) == nil,
                 "A sheet must suspend pinned-header fast routing")
    window.endSheet(sheet); sheet.close(); settle(root)
    NativeTimelineInputGate.shared.setBlocked(true, for: window)
    precondition(NativeTimelineOverlayInputRegistration.hit(in: root, point: lockPoint) == nil)
    NativeTimelineInputGate.shared.setBlocked(false, for: window)
    let popup = NSPanel(contentRect: CGRect(x: 100, y: 100, width: 200, height: 80),
                        styleMask: [.titled], backing: .buffered, defer: false)
    popup.isReleasedWhenClosed = false
    let popupRoot = NSHostingView(rootView: Text("Popup above the header"))
    popup.contentView = popupRoot; popup.orderFront(nil); settle(popupRoot)
    precondition(NativeTimelineOverlayInputRegistration.pinnedRoot(in: popupRoot, point: NSPoint(x: 100, y: 40)) == nil,
                 "A popup/floating window must never route to the underlying document's header")
    popup.close(); window.makeKeyAndOrderFront(nil)
    for width: CGFloat in [400, 260, 0, 340] { state.width = width; settle(root) }
    state.revision = 1; settle(root)
    for index in 0..<5 { click(index) }
    precondition(state.clicks.suffix(5) == ["snap-1", "eye-1", "timebase-1", "lock-1", "add-1"])
    click(3, right: true); precondition(state.rightClicks == 2 && state.options)
    precondition(HeaderUnderlyingControl.contextClicks == 0)
    state.options = false; settle(root)
    window.close()
    print("TRACK_MIXER_HEADER_FIRST_MOUSE_CLICK_RIGHT_CLICK_POPOVER_RESIZE_REOPEN_AND_CURRENT_ACTIONS_OK")
}
