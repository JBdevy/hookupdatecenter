import AppKit
import SwiftUI
import QuartzCore

enum FooterJournal {
    static var rootBodies = 0, playlistReads = 0, made = 0
    static var fontScales: [CGFloat] = []
    static var mixerCommits: [CGFloat] = [], displayCommits: [CGFloat] = []
}
// Stub only model dependencies of the production playlist display.
final class ShowPresentationObserver: ObservableObject {}
struct FooterTestSong { let displayName: String }
struct FooterTestRegion { let startTime: Double; let endTime: Double }
struct FooterTestSubPlay { var playing = false }
struct FooterTestTransport { var subPlay = FooterTestSubPlay() }
struct FooterTestSnapshot { var transport = FooterTestTransport() }
final class ShowController {
    let presentationObserver = ShowPresentationObserver()
    let snapshot = FooterTestSnapshot()
    let current: FooterTestSong? = FooterTestSong(displayName: "Current song")
    let focusedRegion: UUID? = nil
    var listedRegions: [FooterTestRegion] {
        FooterJournal.playlistReads += 1
        return [FooterTestRegion(startTime: 0, endTime: 185)]
    }
}
struct TransportSongDisplays {
    let next: FooterTestSong? = FooterTestSong(displayName: "Next song")
    let queued: FooterTestSong? = FooterTestSong(displayName: "Queued song")
    let nextBPM: Double? = 120, queuedBPM: Double? = 96
    init(song: FooterTestSong?, transport: FooterTestTransport, focusedRegion: UUID?) {}
}

// INSERT_FOOTER_RESIZE_VIEW

private final class FooterGeometryProbeView: NSView {
    var role = ""
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
private struct FooterGeometryProbe: NSViewRepresentable {
    let role: String
    func makeNSView(context: Context) -> FooterGeometryProbeView {
        FooterJournal.made += 1
        let view = FooterGeometryProbeView(); view.role = role; return view
    }
    func updateNSView(_ view: FooterGeometryProbeView, context: Context) {}
}
private struct FooterScrollProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        FooterJournal.made += 1
        let view = NSScrollView(); view.drawsBackground = false
        view.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 4000, height: 1800))
        view.contentView.scroll(to: NSPoint(x: 650, y: 300)); view.reflectScrolledClipView(view.contentView)
        return view
    }
    func updateNSView(_ view: NSScrollView, context: Context) {}
}
private struct FooterResizeFixture: View {
    let coordinator: FooterVerticalResizeCoordinator
    let show: ShowController
    var body: some View {
        let _ = { FooterJournal.rootBodies += 1 }()
        VStack(spacing: 0) {
            FooterGeometryProbe(role: "workspace").frame(maxWidth: .infinity, maxHeight: .infinity)
            FooterNativeHeightHost(storedHeight: 232, minimum: 232, maximum: 723.55859375,
                active: true, identity: "mixer", role: .mixer, resizeCoordinator: coordinator) {
                VStack(spacing: 0) {
                    FooterMixerResizeInput(height: 232, maximum: 723.55859375, changed: { _ in },
                        ended: { FooterJournal.mixerCommits.append($0) }).frame(height: 8)
                    FooterScrollProbe().frame(maxWidth: .infinity, maxHeight: .infinity)
                }.background(FooterGeometryProbe(role: "mixer"))
            }
            FooterNativeHeightHost(storedHeight: 27, minimum: 27, maximum: 161.046875,
                active: true, identity: "display", role: .display, resizeCoordinator: coordinator,
                displayAvailableHeight: 850, fallbackMixerHeight: 232) {
                FooterPlaylistDisplay(show: show, scalesToAvailableHeight: true)
                    .overlay(FooterDisplayResizeInput(height: 27, maximum: 161.046875, changed: { _ in },
                        ended: { FooterJournal.displayCommits.append($0) }))
                    .background(FooterGeometryProbe(role: "display"))
            }
        }
    }
}
private final class FooterKeyboardTarget: NSView, TimelineGridKeyboardTarget {
    override var acceptsFirstResponder: Bool { true }
}
private func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    guard condition() else { FileHandle.standardError.write(Data("line \(line): \(message)\n".utf8)); exit(1) }
}
private func near(_ actual: CGFloat, _ expected: CGFloat) -> Bool { abs(actual - expected) < 0.1 }
private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
}
private func parent<T: NSView>(_ type: T.Type, of view: NSView) -> T? {
    var ancestor = view.superview
    while let value = ancestor { if let match = value as? T { return match }; ancestor = value.superview }
    return nil
}

MainActor.assumeIsolated {
    setbuf(stdout, nil)
    let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
    if CommandLine.arguments.contains("--accessibility") { runFooterAccessibilityFixture(); exit(0) }
    let coordinator = FooterVerticalResizeCoordinator()
    let root = NSHostingView(rootView: FooterResizeFixture(coordinator: coordinator, show: ShowController()))
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1200, height: 900),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = root; window.orderFront(nil)
    defer { window.orderOut(nil); window.close() }
    func pump(_ seconds: Double = 0.03) {
        root.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(seconds)); root.layoutSubtreeIfNeeded()
    }
    pump(0.15)
    let initiallyClosed = FooterHeightContainerView(frame: CGRect(x: 0, y: 0, width: 800, height: 0))
    initiallyClosed.configure(storedHeight: 232, minimum: 232, maximum: 700, active: false, role: .mixer, coordinator: nil)
    var madeClosedContent = 0
    initiallyClosed.setContent(identity: "closed", environment: EnvironmentValues()) {
        madeClosedContent += 1
        return AnyView(FooterScrollProbe())
    }
    expect(madeClosedContent == 0 && initiallyClosed.contentAssignments == 0,
           "closed mixer must not instantiate its controls on first launch")
    expect(initiallyClosed.subviews.allSatisfy(\.isHidden), "closed mixer native subtree must be hidden")
    initiallyClosed.configure(storedHeight: 232, minimum: 232, maximum: 700, active: true, role: .mixer, coordinator: nil)
    initiallyClosed.setContent(identity: "closed", environment: EnvironmentValues()) {
        madeClosedContent += 1
        return AnyView(FooterScrollProbe())
    }
    expect(madeClosedContent == 1 && initiallyClosed.subviews.allSatisfy { !$0.isHidden },
           "opening mounts visible content exactly once")
    let retainedMixerRoot = initiallyClosed.subviews.first!
    initiallyClosed.configure(storedHeight: 232, minimum: 232, maximum: 700, active: false, role: .mixer, coordinator: nil)
    expect(retainedMixerRoot.isHidden, "closing excludes retained controls from tracking traversal")
    initiallyClosed.configure(storedHeight: 232, minimum: 232, maximum: 700, active: true, role: .mixer, coordinator: nil)
    initiallyClosed.setContent(identity: "closed", environment: EnvironmentValues()) {
        madeClosedContent += 1
        return AnyView(FooterScrollProbe())
    }
    expect(madeClosedContent == 1 && initiallyClosed.subviews.first === retainedMixerRoot,
           "reopening preserves the hosted root and its state")
    print("FOOTER_CLOSED_LAZY_MOUNT_HIDDEN_NATIVE_TREE_AND_REOPEN_IDENTITY_OK")
    let mixer = descendants(FooterMixerResizeView.self, in: root).first!
    let display = descendants(FooterDisplayResizeView.self, in: root).first!
    let mixerHost = parent(FooterHeightContainerView.self, of: mixer)!
    let displayHost = parent(FooterHeightContainerView.self, of: display)!
    let scroll = descendants(NSScrollView.self, in: mixerHost).first!
    let keyboard = FooterKeyboardTarget(frame: .zero); root.addSubview(keyboard)
    expect(window.makeFirstResponder(keyboard), "timeline keyboard target must become first responder")
    func at(_ type: NSEvent.EventType, y: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: 200, y: y), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    func initialY(_ view: NSView) -> CGFloat { view.convert(NSPoint(x: 10, y: view.bounds.midY), to: nil).y }
    let rootBodies = FooterJournal.rootBodies, reads = FooterJournal.playlistReads, made = FooterJournal.made
    let mixerAssignments = mixerHost.contentAssignments, displayAssignments = displayHost.contentAssignments
    let identities = Set(descendants(FooterVerticalResizeView.self, in: root).map(ObjectIdentifier.init))
    let document = scroll.documentView!, documentFrame = document.frame
    let initialMixerTop = mixerHost.convert(mixerHost.bounds, to: root).minY
    let mixerY = initialY(mixer)
    mixer.mouseDown(with: at(.leftMouseDown, y: mixerY))
    expect(window.firstResponder === keyboard, "resizing must preserve the timeline keyboard target")
    var timings: [Double] = []
    for delta in 1...60 {
        let started = CFAbsoluteTimeGetCurrent()
        mixer.mouseDragged(with: at(.leftMouseDragged, y: mixerY + CGFloat(delta)))
        timings.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
        expect(near(mixerHost.frame.height, 232 + CGFloat(delta)), "every one-pixel event must reach native mixer geometry synchronously; \(mixerHost.frame.height)")
        expect(near(scroll.frame.height, mixerHost.frame.height - 8), "the native clip viewport must grow in the same event")
        expect(near(mixerHost.convert(mixerHost.bounds, to: root).minY, initialMixerTop - CGFloat(delta)), "the moving edge must follow the exact pointer displacement")
        expect(document.frame == documentFrame && near(scroll.contentView.bounds.minX, 650) && near(scroll.contentView.bounds.minY, 300), "resize must preserve document coordinates and scroll offsets")
        expect(FooterJournal.rootBodies == rootBodies && FooterJournal.playlistReads == reads, "interactive geometry must not reevaluate the outer root or playlist metadata")
        expect(mixerHost.contentAssignments == mixerAssignments && displayHost.contentAssignments == displayAssignments, "interactive resize must retain both SwiftUI roots")
        expect(FooterJournal.made == made && Set(descendants(FooterVerticalResizeView.self, in: root).map(ObjectIdentifier.init)) == identities, "native controls and resize identities must survive every delta")
    }
    mixerHost.configure(storedHeight: 232, minimum: 232, maximum: 723.55859375, active: true, role: .mixer, coordinator: coordinator)
    expect(near(mixerHost.effectiveHeight, 292), "stale configuration during drag must preserve its live height")
    for delta: CGFloat in [90, 25, -1000, 5000, 0, 61] {
        mixer.mouseDragged(with: at(.leftMouseDragged, y: mixerY + delta))
        expect(near(mixerHost.frame.height, min(723.55859375, max(232, 232 + delta))), "bursts, reversal and bounds must apply without a frame wait")
    }
    mixer.mouseUp(with: at(.leftMouseUp, y: mixerY + 47))
    expect(FooterJournal.mixerCommits == [279] && near(mixerHost.frame.height, 279), "mouse-up must apply and commit its own final position once")
    mixerHost.configure(storedHeight: 232, minimum: 232, maximum: 723.55859375, active: true, role: .mixer, coordinator: coordinator)
    pump()
    expect(near(mixerHost.frame.height, 279), "stale defaults after mouse-up must not jump to the old preference")
    mixer.mouseDragged(with: at(.leftMouseDragged, y: mixerY + 200))
    expect(FooterJournal.mixerCommits.count == 1 && near(mixerHost.frame.height, 279), "events after mouse-up must be inert")
    expect(!mixer.cursorPushed, "mouse-up must release its owned cursor")
    print("FOOTER_MIXER_EXACT_60_DELTAS_NATIVE_LAYOUT_ROOT_IDENTITY_SCROLL_AND_FINAL_COMMIT_OK mean_ms=\(timings.reduce(0,+)/Double(timings.count))")

    let displayY = initialY(display)
    FooterJournal.fontScales.removeAll()
    display.mouseDown(with: at(.leftMouseDown, y: displayY))
    display.mouseDragged(with: at(.leftMouseDragged, y: displayY + 120))
    expect(near(displayHost.frame.height, 147), "display resizing must reach its live frame before returning")
    expect(FooterJournal.fontScales.contains { $0 > 2.3 }, "the actual playlist font must grow with local geometry during drag")
    expect(FooterJournal.playlistReads == reads && FooterJournal.rootBodies == rootBodies, "local font geometry must reuse captured playlist content")
    display.mouseUp(with: at(.leftMouseUp, y: displayY + 120))
    expect(FooterJournal.displayCommits == [147], "display must persist once on mouse-up")
    let savedMixerY = initialY(mixer)
    mixer.mouseDown(with: at(.leftMouseDown, y: savedMixerY))
    mixer.mouseDragged(with: at(.leftMouseDragged, y: savedMixerY + 441))
    expect(near(mixerHost.frame.height, 720) && near(displayHost.frame.height, 130), "both native footers must share available height during mixer drag")
    mixer.mouseDragged(with: at(.leftMouseDragged, y: savedMixerY + 350))
    expect(near(mixerHost.frame.height, 629) && near(displayHost.frame.height, 147), "display must restore its preferred height as soon as space returns")
    mixer.mouseUp(with: at(.leftMouseUp, y: savedMixerY + 441))
    expect(near(displayHost.frame.height, 130) && FooterJournal.mixerCommits.last == 720, "coordinated limits must not jump after final commit")
    mixerHost.configure(storedHeight: 720, minimum: 232, maximum: 723.55859375, active: true, role: .mixer, coordinator: coordinator)
    displayHost.configure(storedHeight: 147, minimum: 27, maximum: 161.046875, active: true, role: .display, coordinator: coordinator)
    pump(); expect(near(displayHost.frame.height, 130), "persisted values must preserve the coordinated limit")
    mixerHost.configure(storedHeight: 232, minimum: 232, maximum: 723.55859375, active: true, role: .mixer, coordinator: coordinator)
    pump(); expect(near(displayHost.frame.height, 147), "reducing mixer must restore the saved display preference")
    coordinator.configure(availableHeight: 200, mixerHeight: 180)
    mixerHost.configure(storedHeight: 232, minimum: 232, maximum: 180, active: true, role: .mixer, coordinator: coordinator)
    pump()
    expect(near(mixerHost.frame.height, 180) && near(displayHost.frame.height, 27), "short windows must reserve the same mixer minimum as the outer footer limit")
    mixerHost.configure(storedHeight: 232, minimum: 232, maximum: 180, active: false, role: .mixer, coordinator: coordinator)
    pump(); expect(near(mixerHost.frame.height, 0) && near(displayHost.frame.height, 147), "closing mixer must release its reserved height and retain the display preference")
    coordinator.configure(availableHeight: 850, mixerHeight: 232)
    mixerHost.configure(storedHeight: 232, minimum: 232, maximum: 723.55859375, active: true, role: .mixer, coordinator: coordinator)
    pump()
    print("FOOTER_DISPLAY_LIVE_PRODUCTION_FONTS_CAPTURED_CONTENT_COORDINATED_LIMITS_AND_RESTORE_OK")

    let baseline = mixerHost.effectiveHeight, commits = FooterJournal.mixerCommits.count
    func begin() {
        let y = initialY(mixer); mixer.mouseDown(with: at(.leftMouseDown, y: y)); mixer.mouseDragged(with: at(.leftMouseDragged, y: y + 33))
        expect(mixer.isDragging && mixer.cursorPushed && near(mixerHost.frame.height, baseline + 33), "fixture must enter a live drag")
    }
    func cancelled(_ reason: String) {
        pump()
        expect(!mixer.isDragging && !mixer.cursorPushed && near(mixerHost.frame.height, baseline), "\(reason) must restore geometry and release cursor")
        expect(FooterJournal.mixerCommits.count == commits, "\(reason) must not save a cancelled height")
    }
    expect(!NativeTimelineInputGate.shared.cancelActiveResize(for: window), "idle Escape routing should remain available to ordinary shortcuts")
    begin(); expect(NativeTimelineInputGate.shared.cancelActiveResize(for: window), "Escape must find active native footer resize"); cancelled("Escape")
    begin(); NativeTimelineInputGate.shared.setBlocked(true, for: window); cancelled("modal input gate")
    mixer.mouseDown(with: at(.leftMouseDown, y: initialY(mixer))); expect(!mixer.isDragging, "blocked input must not begin resize")
    NativeTimelineInputGate.shared.setBlocked(false, for: window)
    for notification in [NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification, NSWindow.willBeginSheetNotification, NSWindow.willCloseNotification] {
        begin(); NotificationCenter.default.post(name: notification, object: window); cancelled("window lifecycle \(notification.rawValue)")
    }
    begin(); mixer.isHidden = true; cancelled("hidden handle"); mixer.isHidden = false
    begin(); let oldSuperview = mixer.superview!, oldFrame = mixer.frame
    mixer.removeFromSuperview(); cancelled("detached handle"); oldSuperview.addSubview(mixer); mixer.frame = oldFrame; pump()
    begin(); mixerHost.configure(storedHeight: 232, minimum: 232, maximum: 723.55859375, active: false, role: .mixer, coordinator: coordinator)
    pump()
    expect(!mixer.isDragging && !mixer.cursorPushed && near(mixerHost.frame.height, 0), "deactivating a footer must cancel its gesture and release cursor")
    mixerHost.configure(storedHeight: 232, minimum: 232, maximum: 723.55859375, active: true, role: .mixer, coordinator: coordinator)
    cancelled("deactivated footer")
    begin(); let foreign = FooterMixerResizeView(); foreign.mouseExited(with: at(.mouseMoved, y: 0))
    expect(mixer.cursorPushed && NSCursor.current == NSCursor.resizeUpDown, "another handle must not replace the active drag cursor")
    mixer.cancelDrag(); cancelled("explicit cancel")
    expect(window.firstResponder === keyboard, "all cancellations must preserve timeline keyboard focus")
    let finalRoots = FooterJournal.rootBodies, finalAssignments = mixerHost.contentAssignments + displayHost.contentAssignments
    pump(0.12)
    expect(FooterJournal.rootBodies == finalRoots && mixerHost.contentAssignments + displayHost.contentAssignments == finalAssignments, "idle and completed gestures must have no delayed root work")
    print("FOOTER_RESIZE_ESCAPE_MODAL_WINDOW_HIDE_DETACH_CURSOR_FOCUS_AND_IDLE_QUIETUDE_OK")
}
