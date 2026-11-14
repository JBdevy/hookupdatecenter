import SwiftUI
import AppKit

private final class SidebarResizeCounters {
    var rootEvaluations = 0
    var panelEvaluations = 0
    var chromeUpdates = 0
    var savedWidth: CGFloat = 280
    var commits = 0
    let state = SidebarResizeState()
}
private final class SidebarResizeProbeView: NSView {
    var role = ""
    override var isFlipped: Bool { true }
}
private final class SidebarResizeCommitProbe: NSView, SidebarResizeLayoutBoundary {
    var commits = 0
    func commitSidebarResizeLayout() { commits += 1; layoutSubtreeIfNeeded() }
}
private struct SidebarResizeProbe: NSViewRepresentable {
    let role: String
    func makeNSView(context: Context) -> SidebarResizeProbeView {
        let view = SidebarResizeProbeView()
        view.role = role
        return view
    }
    func updateNSView(_ view: SidebarResizeProbeView, context: Context) {}
}
private struct SidebarResizeChrome: NSViewRepresentable {
    let counters: SidebarResizeCounters
    let action: () -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) { counters.chromeUpdates += 1 }
}
private struct SidebarResizePanels: View {
    let counters: SidebarResizeCounters
    let width: CGFloat
    var body: some View {
        let _ = { counters.panelEvaluations += 1 }()
        GeometryReader { geometry in
            HStack(spacing: 0) {
                GridScrollView(axis: .vertical, contentWidth: geometry.size.width - width - 20, contentHeight: 1800) {
                    HStack(spacing: 0) {
                        SidebarResizeProbe(role: "mixer").frame(width: 240, height: 1800)
                        GridScrollView(axis: .horizontal, contentWidth: 4000, contentHeight: 1800) {
                            SidebarResizeProbe(role: "grid").frame(width: 4000, height: 1800)
                        }.frame(width: max(0, geometry.size.width - width - 260), height: 1800)
                    }.frame(width: geometry.size.width - width - 20, height: 1800)
                }
                MixerResizeHandle(width: width, maximum: 500, minimum: 230, direction: -1, onEnd: { final in
                    counters.savedWidth = final
                    counters.commits += 1
                    counters.state.update(nil)
                }, onResize: { counters.state.update($0) }).frame(width: 20)
                SidebarResizeProbe(role: "setlist").frame(width: width)
            }
        }
    }
}
private struct SidebarResizeScopedFixture: View {
    let counters: SidebarResizeCounters
    var body: some View {
        let _ = { counters.rootEvaluations += 1 }()
        VStack(spacing: 0) {
            SidebarResizeChrome(counters: counters, action: {}).frame(height: 60)
            SidebarResizeLayer(state: counters.state) { transient in
                SidebarResizePanels(counters: counters, width: transient ?? counters.savedWidth)
            }
        }
    }
}
private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    let counters = SidebarResizeCounters()
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let root = NSHostingView(rootView: SidebarResizeScopedFixture(counters: counters))
    window.contentView = root
    root.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.06))
    root.layoutSubtreeIfNeeded()
    let divider = descendants(MixerDividerView.self, in: root).first!
    let probes = descendants(SidebarResizeProbeView.self, in: root)
    let setlist = probes.first { $0.role == "setlist" }!
    let grid = probes.first { $0.role == "grid" }!
    let scrolls = descendants(GridNativeScrollView.self, in: root)
    precondition(scrolls.count == 2)
    let outer = scrolls[0], horizontal = scrolls[1]
    outer.contentView.scroll(to: CGPoint(x: 0, y: 300))
    horizontal.contentView.scroll(to: CGPoint(x: 650, y: 0))
    let initialRoots = counters.rootEvaluations
    let initialChrome = counters.chromeUpdates
    let nativeIdentities = Set(probes.map(ObjectIdentifier.init))
    let initialBarX = divider.convert(CGPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil).x
    let eventY = divider.convert(CGPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil).y
    func event(_ type: NSEvent.EventType, delta: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: initialBarX + delta, y: eventY), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    divider.mouseDown(with: event(.leftMouseDown, delta: 0))
    var timings: [Double] = []
    for delta in [CGFloat(-4), -12, -80, -160, -40, 15, -90, 0, -180, -30] {
        let previousPanels = counters.panelEvaluations
        let started = CFAbsoluteTimeGetCurrent()
        divider.mouseDragged(with: event(.leftMouseDragged, delta: delta))
        timings.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
        precondition(counters.panelEvaluations == previousPanels,
                     "pointer delivery must not synchronously rebuild the SwiftUI panels")
        // A display pass consumes the latest transient width. Pointer delivery
        // itself must stay free of forced hosted-subtree layout.
        root.layoutSubtreeIfNeeded()
        let expectedWidth = min(500, max(230, 280 - delta))
        let actualBarX = divider.convert(CGPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil).x
        precondition(abs(setlist.frame.width - expectedWidth) < 0.1,
                     "the display pass applies the latest pointer width")
        precondition(abs(actualBarX - (initialBarX + 280 - expectedWidth)) < 0.1,
                     "the native divider remains at the pointer's exact horizontal displacement")
        precondition(counters.rootEvaluations == initialRoots && counters.chromeUpdates == initialChrome,
                     "transient resize never reevaluates the app root or unrelated transport chrome")
        precondition(counters.commits == 0 && counters.savedWidth == 280,
                     "interactive width changes do not persist through the app root")
        precondition(Set(descendants(SidebarResizeProbeView.self, in: root).map(ObjectIdentifier.init)) == nativeIdentities,
                     "resizing keeps existing native content and input identities")
        precondition(abs(outer.contentView.bounds.minY - 300) < 0.1 && abs(horizontal.contentView.bounds.minX - 650) < 0.1,
                     "both timeline scroll positions remain exact during sidebar resize")
        precondition(grid.frame.size == CGSize(width: 4000, height: 1800),
                     "sidebar resize changes only the viewport, not timeline document coordinates")
    }
    for delta: CGFloat in [-130, -180, -20] {
        divider.mouseDragged(with: event(.leftMouseDragged, delta: delta))
    }
    root.layoutSubtreeIfNeeded()
    precondition(abs(setlist.frame.width - 300) < 0.1,
                 "a burst/reversal renders the latest width rather than replaying intermediate widths")
    divider.mouseDragged(with: event(.leftMouseDragged, delta: -190))
    divider.mouseUp(with: event(.leftMouseUp, delta: -55))
    precondition(counters.commits == 1 && counters.savedWidth == 335 && counters.state.width == nil,
                 "mouse-up commits the exact final width once and clears transient state")
    precondition(abs(setlist.frame.width - 335) < 0.1, "ending the gesture does not jump back to the old width")
    precondition(counters.rootEvaluations == initialRoots, "the isolated width model does not publish into its parent")
    let completedWidth = setlist.frame.width
    let completedEvaluations = counters.panelEvaluations
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    precondition(setlist.frame.width == completedWidth && counters.panelEvaluations == completedEvaluations,
                 "a completed gesture has no deferred horizontal work")
    // Exiting an unrelated handle must not replace an active drag cursor.
    let other = MixerDividerView(frame: NSRect(x: 0, y: 0, width: 8, height: 100))
    divider.mouseDown(with: event(.leftMouseDown, delta: 0))
    let activeCursor = NSCursor.current
    other.mouseExited(with: event(.mouseMoved, delta: 0))
    precondition(NSCursor.current == activeCursor, "only the active handle owns its resize cursor")
    divider.mouseUp(with: event(.leftMouseUp, delta: 0))
    divider.mouseExited(with: event(.mouseMoved, delta: 0))
    precondition(NSCursor.current != activeCursor, "leaving a released handle restores the pointer")
    print("SIDEBAR_RESIZE_SCOPED_ROOT_NATIVE_GEOMETRY_IDENTITY_SCROLL_AND_FINAL_COMMIT_OK mean_ms=\(timings.reduce(0,+)/Double(timings.count))")
    let boundary = SidebarResizeCommitProbe(frame: root.bounds)
    let burstDivider = MixerDividerView(frame: CGRect(x: 300, y: 0, width: 6, height: 400))
    boundary.addSubview(burstDivider)
    window.contentView = boundary
    burstDivider.columnWidth = 300; burstDivider.maximum = 500
    var liveWidth: CGFloat = 300, finalWidth: CGFloat?
    burstDivider.onResize = { liveWidth = $0; boundary.needsLayout = true }
    burstDivider.onEnd = { finalWidth = $0 }
    burstDivider.mouseDown(with: event(.leftMouseDown, delta: 0))
    for delta in 4...100 { burstDivider.mouseDragged(with: event(.leftMouseDragged, delta: CGFloat(delta))) }
    precondition(boundary.commits == 0 && liveWidth == 400,
                 "a pointer burst must update its destination without forcing a hosted layout per event")
    burstDivider.mouseUp(with: event(.leftMouseUp, delta: 83))
    precondition(boundary.commits == 1 && finalWidth == 383,
                 "release commits the exact final pointer once without replaying earlier movements")
    print("SIDEBAR_RESIZE_BURST_DEFERS_FORCED_HOST_LAYOUT_AND_COMMITS_FINAL_POINTER_ONCE_OK")
    // A pending drag must remain in AppKit's queue until normal dispatch.
    // Peeking here used to enter display/layout while processing this event.
    burstDivider.mouseDown(with: event(.leftMouseDown, delta: 0))
    let queued = event(.leftMouseDragged, delta: 95)
    NSApp.postEvent(queued, atStart: true)
    burstDivider.mouseDragged(with: event(.leftMouseDragged, delta: 25))
    precondition(liveWidth == burstDivider.columnWidth + 25, "Divider must apply the delivered pointer without reading future events")
    let pending = NSApp.nextEvent(matching: .leftMouseDragged, until: .distantPast, inMode: .default, dequeue: true)
    precondition(pending?.locationInWindow == queued.locationInWindow, "Divider must leave queued drag input to the normal event loop")
    burstDivider.mouseUp(with: event(.leftMouseUp, delta: 25))
    print("SIDEBAR_RESIZE_DOES_NOT_PUMP_OR_CONSUME_THE_APPKIT_EVENT_QUEUE_OK")
    window.close()
}

MainActor.assumeIsolated {
    final class SlowFallback: NSView {
        var hits = 0
        override func hitTest(_ point: NSPoint) -> NSView? { hits += 1; return super.hitTest(point) }
    }
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let nativeHost = NativeWorkspaceHostingView(rootView: AnyView(Color.clear))
    window.contentView = nativeHost; nativeHost.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    let wrapper = SlowFallback(frame: nativeHost.bounds)
    nativeHost.addSubview(wrapper)
    let divider = MixerDividerView(frame: CGRect(x: 200, y: 0, width: 6, height: 300))
    wrapper.addSubview(divider)
    let point = nativeHost.superview!.convert(divider.convert(CGPoint(x: 3, y: 120), to: nil), from: nil)
    precondition(nativeHost.hitTest(point) === divider && wrapper.hits == 0,
                 "The outer workspace must resolve a visible native divider before the hosting tree")
    NativeTimelineInputGate.shared.setBlocked(true, for: window)
    _ = nativeHost.hitTest(point)
    precondition(wrapper.hits > 0, "A blocked workspace must use its ordinary overlay/modal route")
    NativeTimelineInputGate.shared.setBlocked(false, for: window)
    window.close()
    print("WORKSPACE_NATIVE_DIVIDER_ROUTE_AND_BLOCKED_MODAL_FALLBACK_OK")
}

for rate in [15.0, 20, 30, 60, 120, 240] {
    var velocity = NativeMixerScrollVelocity()
    _ = velocity.limit(0, timestamp: 100, viewport: 600, precise: true)
    var distance: CGFloat = 0
    for index in 1...Int(rate) { distance += velocity.limit(1000, timestamp: 100+Double(index)/rate, viewport: 600, precise: true) }
    precondition(abs(distance-NativeMixerScrollVelocity.maximum(viewport: 600)) < 0.001, "Equal-duration flicks must have the same speed cap at different input frequencies")
    precondition(velocity.limit(-1, timestamp: 101.02, viewport: 600, precise: true) == -1, "Reversal is immediate and precise")
}
print("MIXER_MAXIMUM_VELOCITY_IS_TIME_BASED_AND_PRESERVES_SMALL_MOVEMENTS_OK")
