import SwiftUI
import AppKit

private final class MixerLifecycleCounters {
    var created = 0
    var updated = 0
    var dismantled = 0
    var detached = 0
    var contentEvaluations = 0
    var tileOffsets: [CGFloat] = []
    var controls: [Int: NSView] = [:]
}
private final class MixerControlView: NSView {
    let counters: MixerLifecycleCounters
    private var hasBeenAttached = false
    init(counters: MixerLifecycleCounters) { self.counters = counters; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { hasBeenAttached = true }
        else if hasBeenAttached { counters.detached += 1 }
    }
}
private struct MixerControlProbe: NSViewRepresentable {
    let id: Int
    let counters: MixerLifecycleCounters
    func makeNSView(context: Context) -> MixerControlView {
        counters.created += 1
        let view = MixerControlView(counters: counters)
        counters.controls[id] = view
        return view
    }
    func updateNSView(_ view: MixerControlView,context: Context) { counters.updated += 1 }
    static func dismantleNSView(_ view: MixerControlView,coordinator: Void) { view.counters.dismantled += 1 }
}
private struct CanvasTileProbe: NSViewRepresentable {
    let offset: CGFloat
    let counters: MixerLifecycleCounters
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView,context: Context) { counters.tileOffsets.append(offset) }
}
private struct MixerLifecycleFixture: View {
    let vertical: TimelineVerticalScroll
    let counters: MixerLifecycleCounters
    var zoom: Double = 1
    var collapsed = false
    private let rowHeight: CGFloat = 72
    private let headerHeight: CGFloat = 71
    private var height: CGFloat { headerHeight + rowHeight * 202 }
    private func mixerContent(_ visibleY: CGFloat) -> some View {
        counters.contentEvaluations += 1
        return VStack(spacing: 0) {
            Color.clear.frame(height: headerHeight)
            ForEach(0..<200,id: \.self) { index in
                if mixerRowIsMounted(start: headerHeight + CGFloat(index) * rowHeight,height: rowHeight,visibleY: visibleY,viewportHeight: 600) {
                    MixerControlProbe(id: index,counters: counters).frame(height: rowHeight)
                } else { Color.clear.frame(height: rowHeight) }
            }
            Color.clear.frame(height: rowHeight * 2)
        }.frame(width: 240,height: height,alignment: .topLeading)
    }
    var body: some View {
        GridScrollView(axis: .vertical,contentWidth: 800,contentHeight: height) {
            TimelineColumnsLayout(mixerWidth: collapsed ? 0 : 240, viewportWidth: 800, height: height) {
                TimelineMixerLayer(position: vertical.tiles, identity: TimelineMixerIdentity(revision: 0, song: nil, width: 240, heights: Array(repeating: rowHeight, count: 200), selection: [])) { mixerContent($0) }.equatable().frame(width: 240).frame(width: collapsed ? 0 : 240, alignment: .leading).clipped().allowsHitTesting(!collapsed)
                Color.clear.frame(width: 4)
                TimelineScrollLayer(position: vertical.tiles) {
                    CanvasTileProbe(offset: $0,counters: counters).frame(width: 560 * zoom,height: height)
                }
            }.frame(width: 800,height: height,alignment: .topLeading)
        }.frame(width: 800,height: 600)
    }
}
private func descendants<T: NSView>(_ type: T.Type,in view: NSView) -> [T] {
    var result: [T] = []
    if let match = view as? T { result.append(match) }
    for child in view.subviews { result.append(contentsOf: descendants(type,in: child)) }
    return result
}
let application = NSApplication.shared
private let vertical = TimelineVerticalScroll()
private let counters = MixerLifecycleCounters()
let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 800,height: 600),styleMask: [.titled],backing: .buffered,defer: false)
window.isReleasedWhenClosed = false
private let root = NSHostingView(rootView: MixerLifecycleFixture(vertical: vertical,counters: counters))
window.contentView = root
root.layoutSubtreeIfNeeded()
RunLoop.main.run(until: Date().addingTimeInterval(0.080))
root.layoutSubtreeIfNeeded()
// NSHostingView installs its final root environment on the first assignment.
// Settle an identical root before measuring subsequent interactive updates.
root.rootView = MixerLifecycleFixture(vertical: vertical, counters: counters)
root.layoutSubtreeIfNeeded()
RunLoop.main.run(until: Date().addingTimeInterval(0.080))
let scrolls = descendants(GridNativeScrollView.self,in: root)
precondition(scrolls.count == 1)
let scroll = scrolls[0]
precondition(counters.created == 200 && counters.controls.count == 200,"all mixer controls mount once even when most tracks are outside the initial viewport")
let controlIdentities = counters.controls.mapValues(ObjectIdentifier.init)
let initialContentEvaluations = counters.contentEvaluations
let initialUpdates = counters.updated
let initialDismantles = counters.dismantled
let initialDetaches = counters.detached
scroll.contentView.postsBoundsChangedNotifications = true
let observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,object: scroll.contentView,queue: .main) { _ in
    vertical.update(scroll.contentView.bounds.minY)
}
var visitedBuckets = Set<CGFloat>()
for y: CGFloat in [96,256,510,513,1_025,1_537,2_049,4_097,8_193,12_289,13_900,1_024,0] {
    scroll.contentView.scroll(to: CGPoint(x: 0,y: y))
    scroll.reflectScrolledClipView(scroll.contentView)
    RunLoop.main.run(until: Date().addingTimeInterval(0.025))
    let expected = floor(max(0,scroll.contentView.bounds.minY) / 512) * 512
    visitedBuckets.insert(expected)
    precondition(vertical.tiles.offset == expected && counters.tileOffsets.last == expected,"the observed canvas probe receives each latest native tile bucket")
    precondition(counters.created == 200 && counters.dismantled == initialDismantles && counters.detached == initialDetaches,"crossing tile buckets never creates, dismantles or detaches mixer controls")
    precondition(counters.controls.mapValues(ObjectIdentifier.init) == controlIdentities,"every mounted mixer control retains its native view identity")
    precondition(counters.contentEvaluations == initialContentEvaluations && counters.updated == initialUpdates,"tile publication never reevaluates the mixer content or updates its controls")
}
precondition(visitedBuckets.count >= 8,"the fixture crosses enough canvas buckets to exercise entering and leaving distant mixer rows")
precondition(Set(counters.tileOffsets).isSuperset(of: visitedBuckets),"canvas updates remain active while mixer updates stay isolated")
for step in 1...20 {
    root.rootView = MixerLifecycleFixture(vertical: vertical, counters: counters, zoom: 1 + Double(step) / 100)
    root.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
}
precondition(counters.contentEvaluations == initialContentEvaluations, "horizontal scale changes must not rebuild the mixer: \(counters.contentEvaluations) vs \(initialContentEvaluations)")
precondition(counters.controls.mapValues(ObjectIdentifier.init) == controlIdentities, "zoom keeps the same native controls")
for step in 0..<12 {
    root.rootView = MixerLifecycleFixture(vertical: vertical, counters: counters, zoom: 1.2, collapsed: step % 2 == 0)
    root.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    precondition(counters.created == 200 && counters.dismantled == initialDismantles && counters.detached == initialDetaches, "hiding and restoring the mixer must retain all native controls")
    precondition(counters.controls.mapValues(ObjectIdentifier.init) == controlIdentities, "toggle restores the same faders and meters")
}
NotificationCenter.default.removeObserver(observer)
print("TIMELINE_MIXER_LIFECYCLE_OK rows=200 created=" + String(counters.created) + " contentEvaluations=" + String(counters.contentEvaluations) + " canvasBuckets=" + String(visitedBuckets.count) + " dismantled=" + String(counters.dismantled) + " detached=" + String(counters.detached))
window.close()
