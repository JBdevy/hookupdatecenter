import AppKit

final class SidebarHitProbeClip: NSClipView {
    var hitCount = 0
    override func hitTest(_ point: NSPoint) -> NSView? {
        hitCount += 1
        return super.hitTest(point)
    }
}
final class SidebarFixtureDocument: NSView {
    var hitCount = 0
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        hitCount += 1
        return super.hitTest(point)
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

func settle(_ seconds: TimeInterval = 0.04) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
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

// The mixer shares its vertical document with a horizontal timeline. Wheel
// zoom there must pass through without first walking the whole hosting tree.
mixerController.scroll(to: 0)
physicalWheel.precise = false; physicalWheel.delta = -4
let timelineScroll = NSScrollView(frame: CGRect(x: 140, y: 0, width: 140, height: 400))
timelineScroll.borderType = .noBorder
timelineScroll.documentView = SidebarFixtureDocument(frame: CGRect(x: 0, y: 0, width: 4000, height: 400))
mixerScroll.documentView!.addSubview(timelineScroll)
timelineScroll.tile()
SidebarScrollController.registerTimelineWheelClip(timelineScroll.contentView)
physicalWheel.point = timelineScroll.contentView.convert(CGPoint(x: 70, y: 100), to: nil)
let hitsBeforeTimelineZoom = root.hitCount
let offsetBeforeTimelineZoom = mixerController.metrics.offset
for _ in 0..<120 {
    precondition(!mixerController.handleWheel(physicalWheel), "the registered inner timeline owns physical wheel input")
}
precondition(root.hitCount == hitsBeforeTimelineZoom && mixerController.metrics.offset == offsetBeforeTimelineZoom,
             "timeline zoom neither hit-tests the root nor scrolls the mixer")

let overlay = NSView(frame: CGRect(x: 0, y: 0, width: 280, height: 400))
root.addSubview(overlay)
precondition(!mixerController.handleWheel(physicalWheel), "overlapping panels keep the timeline event on its normal route")
physicalWheel.point = mixerScroll.contentView.convert(CGPoint(x: 70, y: 100), to: nil)
let hitsBeforeOverlay = root.hitCount
precondition(!mixerController.handleWheel(physicalWheel) && root.hitCount > hitsBeforeOverlay,
             "sibling panels outside the timeline still take precedence through root hit-testing")
overlay.removeFromSuperview()
precondition(mixerController.handleWheel(physicalWheel), "ordinary mixer space keeps physical-wheel scrolling")
mixerController.scroll(to: 0)

physicalWheel.point = timelineScroll.contentView.convert(CGPoint(x: 70, y: 100), to: nil)
timelineScroll.isHidden = true
let hitsBeforeHiddenTimeline = root.hitCount
precondition(mixerController.handleWheel(physicalWheel) && root.hitCount > hitsBeforeHiddenTimeline,
             "hidden timeline clips cannot exclude the underlying mixer")
mixerController.scroll(to: 0)
timelineScroll.isHidden = false
timelineScroll.removeFromSuperview()
let hitsBeforeDetachedTimeline = root.hitCount
precondition(mixerController.handleWheel(physicalWheel) && root.hitCount > hitsBeforeDetachedTimeline,
             "detached timeline clips cannot exclude the mixer")
mixerController.scroll(to: 0)
setlistScroll.documentView!.addSubview(timelineScroll)
precondition(mixerController.handleWheel(physicalWheel), "a registered clip in another scroll view cannot exclude this mixer")
timelineScroll.removeFromSuperview()
weak var releasedTimelineClip: NSClipView?
do {
    let clip = NSClipView()
    releasedTimelineClip = clip
    SidebarScrollController.registerTimelineWheelClip(clip)
}
precondition(releasedTimelineClip == nil, "timeline wheel registration does not retain removed native views")
print("SIDEBAR_TIMELINE_WHEEL_EXCLUSION_NO_ROOT_HIT_TEST_OVERLAY_HIDDEN_DETACH_AND_LIFETIME_OK")


mixerController.attach(nil); setlistController.attach(nil)
window.close()
}
