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
        let started = CFAbsoluteTimeGetCurrent()
        divider.mouseDragged(with: event(.leftMouseDragged, delta: delta))
        timings.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
        let expectedWidth = min(500, max(230, 280 - delta))
        let actualBarX = divider.convert(CGPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil).x
        precondition(abs(setlist.frame.width - expectedWidth) < 0.1,
                     "the actual native panel reaches each latest pointer width before layout returns")
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
        precondition(abs(setlist.frame.width - (280 - delta)) < 0.1,
                     "every horizontal burst/reversal reaches native geometry in the event without a display-frame wait")
    }
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
    window.close()
}
