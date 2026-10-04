import SwiftUI
import AppKit

final class SidebarHitProbeClip: NSClipView {
    var hitCount = 0
    override func hitTest(_ point: NSPoint) -> NSView? {
        hitCount += 1
        return super.hitTest(point)
    }
}
final class SidebarFixtureDocument: NSView { override var isFlipped: Bool { true } }
private final class HostedSidebarCounts { var resized = 0; var bodies = 0 }
private struct HostedSidebarFixture: View {
    let controller: SidebarScrollController
    let counts: HostedSidebarCounts
    var body: some View {
        let _ = counts.bodies += 1
        HStack(spacing: 0) {
            MixerResizeHandle(width: 240, maximum: 480, scrollController: controller, onResize: { _ in counts.resized += 1 })
                .frame(width: 6)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(0..<100) { Text("Song \($0)").frame(height: 28) }
                }.background(SidebarScrollProbe(controller: controller))
            }.scrollIndicators(.hidden)
        }
    }
}
MainActor.assumeIsolated {
_ = NSApplication.shared
let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
let root = SidebarFixtureDocument(frame: CGRect(x: 0, y: 0, width: 800, height: 500))
window.contentView = root
func makeScroll(x: CGFloat, documentHeight: CGFloat) -> NSScrollView {
    let scroll = NSScrollView(frame: CGRect(x: x, y: 0, width: 280, height: 400))
    scroll.contentView = SidebarHitProbeClip()
    scroll.borderType = .noBorder
    scroll.hasVerticalScroller = false
    scroll.documentView = SidebarFixtureDocument(frame: CGRect(x: 0, y: 0, width: 280, height: documentHeight))
    root.addSubview(scroll)
    scroll.tile()
    return scroll
}
let mixerScroll = makeScroll(x: 0, documentHeight: 2000)
let setlistScroll = makeScroll(x: 400, documentHeight: 1200)
let mixerController = SidebarScrollController(), setlistController = SidebarScrollController()
let mixerProbe = SidebarScrollProbeView(frame: .zero)
mixerProbe.controller = mixerController
mixerScroll.documentView!.addSubview(mixerProbe)
mixerProbe.attach()
let setlistProbe = SidebarScrollProbeView(frame: .zero)
setlistProbe.controller = setlistController
setlistScroll.documentView!.addSubview(setlistProbe)
setlistProbe.attach()
precondition(mixerController.scrollView === mixerScroll && setlistController.scrollView === setlistScroll, "each probe attaches only its own enclosing sidebar scroll view")
let divider = MixerDividerView(frame: CGRect(x: 280, y: 0, width: 12, height: 400))
divider.scrollController = mixerController
divider.columnWidth = 230; divider.minimum = 160; divider.maximum = 480
root.addSubview(divider)
var widths: [CGFloat] = [], completed: [CGFloat] = [], starts = 0, toggles = 0
divider.onResize = { widths.append($0) }; divider.onEnd = { completed.append($0) }
divider.onStart = { starts += 1 }; divider.onToggle = { toggles += 1 }
func pointer(_ view: NSView, _ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
}
func settle(_ seconds: TimeInterval = 0.04) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
precondition(mixerController.metrics.documentHeight == 2000 && mixerController.metrics.viewportHeight == 400 && mixerController.metrics.offset == 0)
precondition(divider.scrollIndicatorVisible, "a scrollable sidebar always displays its thumb before the pointer enters")
let hover = pointer(divider, .mouseMoved, CGPoint(x: 6, y: 50))
divider.mouseEntered(with: hover)
settle()
precondition(divider.scrollIndicatorVisible, "hover keeps the permanent scrollbar visible")
precondition(abs(divider.scrollThumbRect.height - 79.2) < 0.001, "thumb size reflects visible versus total sidebar content")
divider.mouseDown(with: pointer(divider, .leftMouseDown, CGPoint(x: 6, y: 50)))
divider.mouseDragged(with: pointer(divider, .leftMouseDragged, CGPoint(x: 7, y: 52)))
precondition(mixerController.metrics.offset == 0 && widths.isEmpty, "pointer jitter below three points does not scroll or resize")
divider.mouseDragged(with: pointer(divider, .leftMouseDragged, CGPoint(x: 7, y: 90)))
precondition(mixerController.metrics.offset > 150 && setlistController.metrics.offset == 0 && widths.isEmpty && starts == 0, "vertical dragging scrolls only the mixer without starting a width edit")
let firstScroll = mixerController.metrics.offset
divider.mouseDragged(with: pointer(divider, .leftMouseDragged, CGPoint(x: 90, y: 95)))
precondition(mixerController.metrics.offset > firstScroll, "later drag events move synchronously with the pointer")
divider.advanceScrollFrame()
precondition(mixerController.metrics.offset > firstScroll && widths.isEmpty, "vertical axis remains locked even if pointer subsequently moves far sideways")
divider.mouseExited(with: pointer(divider, .mouseMoved, CGPoint(x: 90, y: 95)))
settle()
precondition(divider.scrollIndicatorVisible, "dragging outside the narrow divider never hides its scrollbar")
divider.mouseUp(with: pointer(divider, .leftMouseUp, CGPoint(x: 90, y: 95)))
precondition(completed.isEmpty && toggles == 0)
settle()
precondition(divider.scrollIndicatorVisible, "the scrollbar remains visible after release outside the divider")

let offsetBeforeResize = mixerController.metrics.offset
divider.mouseDown(with: pointer(divider, .leftMouseDown, CGPoint(x: 6, y: 50)))
divider.mouseDragged(with: pointer(divider, .leftMouseDragged, CGPoint(x: 26, y: 51)))
divider.mouseDragged(with: pointer(divider, .leftMouseDragged, CGPoint(x: 36, y: 190)))
divider.mouseUp(with: pointer(divider, .leftMouseUp, CGPoint(x: 36, y: 190)))
precondition(starts == 1 && completed == [260] && widths.last == 260, "horizontal dragging retains resize callbacks and original width calculation")
precondition(mixerController.metrics.offset == offsetBeforeResize, "horizontal axis stays locked despite subsequent vertical movement")
divider.mouseDown(with: pointer(divider, .leftMouseDown, CGPoint(x: 6, y: 40), clicks: 2))
precondition(toggles == 1, "double-click still toggles sidebar collapse")
divider.columnWidth = 0
divider.mouseDown(with: pointer(divider, .leftMouseDown, CGPoint(x: 6, y: 40)))
divider.mouseUp(with: pointer(divider, .leftMouseUp, CGPoint(x: 6, y: 40)))
precondition(toggles == 2, "clicking a collapsed sidebar's divider restores it")

divider.mouseEntered(with: hover)
divider.mouseExited(with: hover)
settle(1.05)
precondition(divider.scrollIndicatorVisible, "pointer exit and prolonged inactivity never hide the permanent scrollbar")
divider.mouseMoved(with: hover)
precondition(NSCursor.current.image.size == NSSize(width: 24, height: 24), "hover uses the cached four-arrow move cursor")
divider.mouseExited(with: pointer(divider, .mouseMoved, CGPoint(x: 90, y: 50)))
precondition(NSCursor.current == NSCursor.arrow, "leaving the scrollbar restores the pointer without needing a click")
divider.cursorUpdate(with: hover)
precondition(NSCursor.current.image.size == NSSize(width: 24, height: 24), "AppKit cursor updates restore the divider cursor on reentry")
divider.mouseDown(with: pointer(divider, .leftMouseDown, CGPoint(x: 6, y: 50)))
divider.mouseDragged(with: pointer(divider, .leftMouseDragged, CGPoint(x: 60, y: 80)))
divider.mouseExited(with: pointer(divider, .mouseMoved, CGPoint(x: 60, y: 80)))
precondition(NSCursor.current.image.size == NSSize(width: 24, height: 24), "an active divider drag keeps its cursor outside the narrow rail")
divider.mouseUp(with: pointer(divider, .leftMouseUp, CGPoint(x: 60, y: 80)))
precondition(NSCursor.current == NSCursor.arrow, "releasing outside the rail clears the drag cursor")


let listDivider = MixerDividerView(frame: CGRect(x: 390, y: 0, width: 6, height: 400))
listDivider.scrollController = setlistController; listDivider.direction = -1
listDivider.columnWidth = 277; listDivider.minimum = 200; listDivider.maximum = 480
root.addSubview(listDivider)
var listWidth: CGFloat = 0
listDivider.onEnd = { listWidth = $0 }
listDivider.mouseDown(with: pointer(listDivider, .leftMouseDown, CGPoint(x: 3, y: 50)))
listDivider.mouseDragged(with: pointer(listDivider, .leftMouseDragged, CGPoint(x: 3, y: 110)))
listDivider.mouseUp(with: pointer(listDivider, .leftMouseUp, CGPoint(x: 3, y: 110)))
precondition(setlistController.metrics.offset > 0 && mixerController.metrics.offset == offsetBeforeResize && listWidth == 0, "Setlist vertical dragging is independent from mixer and has no width callback")
listDivider.mouseDown(with: pointer(listDivider, .leftMouseDown, CGPoint(x: 3, y: 50)))
listDivider.mouseUp(with: pointer(listDivider, .leftMouseUp, CGPoint(x: -20, y: 50)))
precondition(listWidth == 300, "leftward resize preserves the Setlist's reversed horizontal direction")

mixerController.scroll(to: 1_000_000)
precondition(mixerController.metrics.offset == 1600 && abs(divider.scrollThumbRect.maxY - 398) < 0.001, "dragging clamps exactly at the content end and thumb reaches the rail bottom")
mixerController.scroll(to: -500)
precondition(mixerController.metrics.offset == 0 && divider.scrollThumbRect.minY == 2)
mixerScroll.contentView.scroll(to: CGPoint(x: 0, y: 300))
mixerScroll.reflectScrolledClipView(mixerScroll.contentView)
precondition(mixerController.metrics.offset == 300, "native trackpad or wheel scrolling updates the thumb through bounds notifications")
mixerScroll.documentView!.setFrameSize(CGSize(width: 280, height: 3200))
precondition(mixerController.metrics.documentHeight == 3200, "new items change scrollbar geometry through native document frame notifications")

let unflipped = NSScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
unflipped.documentView = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 1000))
let otherController = SidebarScrollController(); otherController.attach(unflipped)
otherController.scroll(to: 0)
precondition(unflipped.contentView.bounds.minY == 800 && otherController.metrics.offset == 0, "top-to-bottom scrollbar coordinates also support unflipped native documents")
otherController.scroll(to: 800)
precondition(unflipped.contentView.bounds.minY == 0 && otherController.metrics.offset == 800)

// A physical wheel applies its exact step immediately; trackpad keeps native momentum.
final class SidebarWheelEvent: NSEvent {
    var targetWindow: NSWindow!
    var point = NSPoint.zero
    var delta: CGFloat = -4
    var precise = false
    override var window: NSWindow? { targetWindow }
    override var locationInWindow: NSPoint { point }
    override var scrollingDeltaY: CGFloat { delta }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
}
mixerController.scroll(to: 0)
let physicalWheel = SidebarWheelEvent()
physicalWheel.targetWindow = window
physicalWheel.point = mixerScroll.convert(NSPoint(x: 100, y: 100), to: nil)
precondition(mixerController.handleWheel(physicalWheel))
let firstWheelPosition = mixerController.metrics.offset
precondition(abs(firstWheelPosition - 64) < 0.001, "physical wheel applies its complete step immediately")
settle(0.65)
precondition(abs(mixerController.metrics.offset - 64) < 0.001, "wheel settles at its exact distance")
physicalWheel.delta = -8
precondition(mixerController.handleWheel(physicalWheel))
settle(0.03)
let beforeReversal = mixerController.metrics.offset
physicalWheel.delta = 2
precondition(mixerController.handleWheel(physicalWheel))
settle(0.65)
precondition(abs(mixerController.metrics.offset - max(0, beforeReversal - 32)) < 0.001, "reversal cancels outstanding travel")
physicalWheel.precise = true
let hitProbe = mixerScroll.contentView as! SidebarHitProbeClip
let previousHits = hitProbe.hitCount
for _ in 0..<120 {
    precondition(!mixerController.handleWheel(physicalWheel), "trackpad remains native")
}
precondition(hitProbe.hitCount == previousHits, "trackpad zoom must not hit-test the sidebar's entire hosted document")
print("SIDEBAR_PHYSICAL_WHEEL_IMMEDIATE_EXACT_TARGET_AND_REVERSAL_OK")

// Every thumb event commits immediately, including reversal and mouse-up.
mixerController.scroll(to: 0)
divider.columnWidth = 230
var preparedTargets: [CGFloat] = []
mixerController.prepareScroll = { offset in preparedTargets.append(offset); return false }
let ratio = mixerController.metrics.maximumOffset / (divider.bounds.height - 4 - divider.scrollThumbRect.height)
divider.mouseDown(with: pointer(divider, .leftMouseDown, CGPoint(x: 6, y: 200)))
divider.mouseDragged(with: pointer(divider, .leftMouseDragged, CGPoint(x: 6, y: 240)))
precondition(preparedTargets.count == 1 && abs(mixerController.metrics.offset - 40 * ratio) < 0.01, "first drag destination commits immediately with no rate or distance cap")
for y: CGFloat in [320, 270, 150] {
    divider.mouseDragged(with: pointer(divider, .leftMouseDragged, CGPoint(x: 6, y: y)))
}
precondition(preparedTargets.count == 4, "every native drag position commits synchronously")
divider.advanceScrollFrame()
precondition(preparedTargets.count == 4 && mixerController.metrics.offset == 0, "the next display frame commits only the latest reversed destination")
divider.mouseDragged(with: pointer(divider, .leftMouseDragged, CGPoint(x: 6, y: 350)))
divider.mouseUp(with: pointer(divider, .leftMouseUp, CGPoint(x: 6, y: 210)))
precondition(preparedTargets.count == 6 && abs(mixerController.metrics.offset - 10 * ratio) < 0.01, "mouse-up immediately flushes its exact newest position and discards an older pending target")
let finalOffset = mixerController.metrics.offset
divider.advanceScrollFrame(); settle()
precondition(preparedTargets.count == 6 && mixerController.metrics.offset == finalOffset, "stopped display links cannot replay old destinations after release")
let detachedDivider = MixerDividerView(frame: CGRect(x: 300, y: 0, width: 20, height: 400))
detachedDivider.scrollController = mixerController; root.addSubview(detachedDivider)
detachedDivider.mouseDown(with: pointer(detachedDivider, .leftMouseDown, CGPoint(x: 10, y: 80)))
detachedDivider.mouseDragged(with: pointer(detachedDivider, .leftMouseDragged, CGPoint(x: 10, y: 100)))
detachedDivider.mouseDragged(with: pointer(detachedDivider, .leftMouseDragged, CGPoint(x: 10, y: 300)))
let offsetBeforeDetach = mixerController.metrics.offset, preparesBeforeDetach = preparedTargets.count
detachedDivider.removeFromSuperview()
detachedDivider.advanceScrollFrame(); settle()
precondition(mixerController.metrics.offset == offsetBeforeDetach && preparedTargets.count == preparesBeforeDetach,
             "detaching the divider cancels every pending frame without moving an old project later")
mixerController.prepareScroll = nil

// Horizontal resizing also publishes every native event immediately.
let resizeDivider = MixerDividerView(frame: CGRect(x: 320, y: 0, width: 20, height: 400))
resizeDivider.columnWidth = 0; resizeDivider.minimum = 160; resizeDivider.maximum = 480
root.addSubview(resizeDivider)
var resizeTargets: [CGFloat] = [], resizeEnds: [CGFloat] = []
resizeDivider.onResize = { resizeTargets.append($0) }
resizeDivider.onEnd = { resizeEnds.append($0) }
resizeDivider.mouseDown(with: pointer(resizeDivider, .leftMouseDown, CGPoint(x: 10, y: 80)))
resizeDivider.mouseDragged(with: pointer(resizeDivider, .leftMouseDragged, CGPoint(x: 14, y: 80)))
precondition(resizeTargets == [160], "dragging from a collapsed panel publishes its minimum width immediately")
for x: CGFloat in [220, 310, 190] {
    resizeDivider.mouseDragged(with: pointer(resizeDivider, .leftMouseDragged, CGPoint(x: x, y: 80)))
    precondition(resizeTargets.last == x - 10, "every width burst reaches its target before mouseDragged returns")
}
precondition(resizeTargets == [160, 210, 300, 180], "horizontal reversals never wait for a display frame")
resizeDivider.mouseDragged(with: pointer(resizeDivider, .leftMouseDragged, CGPoint(x: 390, y: 80)))
resizeDivider.mouseUp(with: pointer(resizeDivider, .leftMouseUp, CGPoint(x: 250, y: 80)))
precondition(resizeTargets == [160, 210, 300, 180, 380, 240] && resizeEnds == [240], "release publishes the exact final width and persists exactly once")
settle()
precondition(resizeTargets.count == 6, "a completed horizontal gesture never replays an earlier target")
resizeDivider.columnWidth = 240
resizeDivider.mouseDown(with: pointer(resizeDivider, .leftMouseDown, CGPoint(x: 10, y: 80)))
resizeDivider.mouseDragged(with: pointer(resizeDivider, .leftMouseDragged, CGPoint(x: 20, y: 80)))
resizeDivider.mouseDragged(with: pointer(resizeDivider, .leftMouseDragged, CGPoint(x: 200, y: 80)))
let targetsBeforeDetach = resizeTargets
resizeDivider.removeFromSuperview()
settle()
precondition(resizeTargets == targetsBeforeDetach && resizeEnds == [240],
             "detaching a horizontal divider cannot publish or persist any target later")
print("SIDEBAR_HORIZONTAL_FIRST_FRAME_BURST_REVERSAL_COLLAPSED_FINAL_COMMIT_AND_DETACH_OK")

let replacementProbe = SidebarScrollProbeView(frame: .zero)
replacementProbe.controller = mixerController; mixerScroll.documentView!.addSubview(replacementProbe); replacementProbe.attach()
mixerController.detach(owner: mixerProbe)
precondition(mixerController.scrollView === mixerScroll, "dismantling an obsolete SwiftUI probe cannot disconnect its replacement")
mixerController.detach(owner: replacementProbe)
precondition(mixerController.scrollView == nil && !mixerController.metrics.canScroll, "removing the active sidebar disconnects native observers and clears the thumb")
precondition(divider.scrollThumbRect.isEmpty)
window.close()
print("SIDEBAR_DIVIDER_AXIS_LOCK_SCROLL_RESIZE_PERMANENT_VISIBILITY_GEOMETRY_PROBE_AND_FRAME_COALESCING_OK")

let hostedController = SidebarScrollController(), hostedCounts = HostedSidebarCounts()
let hostedWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
hostedWindow.isReleasedWhenClosed = false
let hostedRoot = NSHostingView(rootView: HostedSidebarFixture(controller: hostedController, counts: hostedCounts))
hostedWindow.contentView = hostedRoot
hostedRoot.layoutSubtreeIfNeeded(); settle(0.08); hostedRoot.layoutSubtreeIfNeeded()
func findDivider(in view: NSView) -> MixerDividerView? {
    if let divider = view as? MixerDividerView { return divider }
    return view.subviews.lazy.compactMap { findDivider(in: $0) }.first
}
guard let hostedDivider = findDivider(in: hostedRoot), let hostedScroll = hostedController.scrollView else {
    preconditionFailure("the real SwiftUI ScrollView/LazyVStack background must attach its own scroll controller")
}
precondition(hostedController.metrics.canScroll, "real Setlist-style SwiftUI content exposes its scrollable range")
let bodiesBeforeDrag = hostedCounts.bodies
hostedDivider.mouseDown(with: pointer(hostedDivider, .leftMouseDown, CGPoint(x: 3, y: 30)))
hostedDivider.mouseDragged(with: pointer(hostedDivider, .leftMouseDragged, CGPoint(x: 3, y: 120)))
hostedDivider.mouseUp(with: pointer(hostedDivider, .leftMouseUp, CGPoint(x: 3, y: 120)))
settle()
precondition(hostedController.scrollView === hostedScroll && hostedController.metrics.offset > 100,
             "native divider dragging scrolls the actual SwiftUI Setlist viewport")
precondition(hostedCounts.resized == 0 && hostedCounts.bodies == bodiesBeforeDrag,
             "vertical scrollbar interaction never publishes width changes or rebuilds its containing SwiftUI view")
hostedWindow.close()
print("SIDEBAR_SWIFTUI_LAZY_CONTENT_PROBE_AND_NATIVE_SCROLL_WITHOUT_ROOT_REBUILD_OK")
}
