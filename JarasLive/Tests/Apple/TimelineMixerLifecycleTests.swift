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
    let pool = TimelineMixerRowPool<Int>()
}
private final class MixerControlView: NSView {
    let counters: MixerLifecycleCounters
    var id = -1
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
        view.id = id
        counters.controls[id] = view
        return view
    }
    func updateNSView(_ view: MixerControlView,context: Context) {
        counters.updated += 1
        if view.id != id, counters.controls[view.id] === view { counters.controls[view.id] = nil }
        view.id = id
        counters.controls[id] = view
    }
    static func dismantleNSView(_ view: MixerControlView,coordinator: Void) {
        view.counters.dismantled += 1
        if view.counters.controls[view.id] === view { view.counters.controls[view.id] = nil }
    }
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
    var viewportHeight: CGFloat = 600
    var mixerWidth: CGFloat = 240
    var widthViewport: CGRect? = nil
    private let rowHeight: CGFloat = 72
    private let headerHeight: CGFloat = 71
    private var height: CGFloat { headerHeight + rowHeight * 202 }
    private var viewportHeightBucket: CGFloat { ceil(viewportHeight / 512) * 512 }
    private func mixerContent(_ visibleY: CGFloat) -> some View {
        counters.contentEvaluations += 1
        let offsets = (0..<200).map { CGFloat($0) * rowHeight }
        let heights = Array(repeating: rowHeight, count: 200)
        let slots = counters.pool.slots(ids: Array(0..<200), offsets: offsets, heights: heights,
                                        top: headerHeight, visibleY: visibleY, viewportHeight: viewportHeightBucket, width: mixerWidth, widthViewport: widthViewport)
        return TimelineTrackRowsLayout(width: mixerWidth, height: height, top: headerHeight,
                                       offsets: slots.map { offsets[$0.index] }, rowHeights: slots.map { heights[$0.index] }, rowWidths: slots.map { $0.width ?? mixerWidth }) {
            ForEach(slots) { slot in
                MixerControlProbe(id: slot.index, counters: counters).frame(width: slot.width, height: rowHeight)
            }
        }.frame(width: mixerWidth,height: height,alignment: .topLeading)
    }

    var body: some View {
        GridScrollView(axis: .vertical,contentWidth: 800,contentHeight: height) {
            TimelineColumnsLayout(mixerWidth: collapsed ? 0 : mixerWidth, viewportWidth: 800, height: height) {
                TimelineMixerLayer(position: vertical.tiles, identity: TimelineMixerIdentity(revision: 0, song: nil, width: mixerWidth, viewportHeight: viewportHeightBucket, heights: Array(repeating: rowHeight, count: 200), selection: [], widthViewport: widthViewport)) { mixerContent($0) }.equatable().frame(width: mixerWidth).frame(width: collapsed ? 0 : mixerWidth, alignment: .leading).clipped().allowsHitTesting(!collapsed)
                Color.clear.frame(width: 4)
                TimelineScrollLayer(position: vertical.tiles) {
                    CanvasTileProbe(offset: $0,counters: counters).frame(width: 560 * zoom,height: height)
                }
            }.frame(width: 800,height: height,alignment: .topLeading)
        }.frame(width: 800,height: viewportHeight)
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
precondition(counters.controls.count > 8 && counters.controls.count < 40,
             "only the viewport and its overscan mount native mixer controls")
var previousControls = counters.controls.mapValues(ObjectIdentifier.init)
let warmedControlCount = counters.created
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
    let visible = (0..<200).filter { index in
        let top = 71 + CGFloat(index) * 72
        return top + 72 >= scroll.contentView.bounds.minY && top <= scroll.contentView.bounds.maxY
    }
    precondition(visible.allSatisfy { counters.controls[$0] != nil }, "scrolling always has controls ready for every visible row")
    precondition(counters.controls.count < 40, "distant offscreen rows do not accumulate native controls")
    let currentControls = counters.controls.mapValues(ObjectIdentifier.init)
    for id in Set(previousControls.keys).intersection(currentControls.keys) {
        precondition(previousControls[id] == currentControls[id], "rows retained inside the overscan keep their faders and gesture state")
    }
    precondition(counters.created == warmedControlCount && counters.dismantled == 0, "distant jumps reuse the warmed native controls without creating or dismantling rows")
    previousControls = currentControls

}
precondition(visitedBuckets.count >= 8,"the fixture crosses enough canvas buckets to exercise entering and leaving distant mixer rows")
precondition(Set(counters.tileOffsets).isSuperset(of: visitedBuckets),"canvas and mixer cover the same native scroll buckets")
MainActor.assumeIsolated {
let sidebar = SidebarScrollController()
sidebar.attach(scroll, owner: root)
sidebar.prepareScroll = { offset in
    let old = vertical.tiles.offset
    vertical.update(offset)
    return old != vertical.tiles.offset
}
for y: CGFloat in [8193, 0, 4097, 13000, 512, 0] {
    sidebar.scroll(to: y)
    let visible = (0..<200).filter { index in
        let top = 71 + CGFloat(index) * 72
        return top + 72 >= scroll.contentView.bounds.minY && top <= scroll.contentView.bounds.maxY
    }
    precondition(visible.allSatisfy { counters.controls[$0] != nil }, "scrollbar jumps return with every visible row rebound, without waiting for the run loop")
    for id in visible {
        let control = counters.controls[id]!
        let frame = control.convert(control.bounds, to: scroll.documentView!)
        precondition(abs(frame.minY - (71 + CGFloat(id) * 72)) < 0.1 && abs(frame.height - 72) < 0.1,
                     "recycled controls occupy their new track's exact native row frame before the jump returns")
    }
    precondition(counters.created == warmedControlCount && counters.dismantled == 0,
                 "fast reversals do not create, remove or detach the warm row controls")
}
}
let initialContentEvaluations = counters.contentEvaluations
let controlIdentities = counters.controls.mapValues(ObjectIdentifier.init)
let initialCreated = counters.created, initialDismantles = counters.dismantled, initialDetaches = counters.detached
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
    precondition(counters.created == initialCreated && counters.dismantled == initialDismantles && counters.detached == initialDetaches, "hiding and restoring the mixer must retain the mounted native controls")
    precondition(counters.controls.mapValues(ObjectIdentifier.init) == controlIdentities, "toggle restores the same faders and meters")
}
func resizeMixer(to height: CGFloat) {
    root.rootView = MixerLifecycleFixture(vertical: vertical, counters: counters, zoom: 1.2, viewportHeight: height)
    window.setContentSize(CGSize(width: 800, height: height))
    root.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.025))
    root.layoutSubtreeIfNeeded()
    let visible = (0..<200).filter { index in
        let top = 71 + CGFloat(index) * 72
        return top + 72 >= scroll.contentView.bounds.minY && top <= scroll.contentView.bounds.maxY
    }
    precondition(visible.allSatisfy { counters.controls[$0] != nil }, "resizing immediately has controls for every newly visible row")
}
let beforeResizeEvaluations = counters.contentEvaluations
let beforeResizeControls = counters.controls.mapValues(ObjectIdentifier.init)
for height: CGFloat in [601, 620, 750, 999, 1024, 800, 600] {
    resizeMixer(to: height)
    precondition(counters.contentEvaluations == beforeResizeEvaluations,
                 "height changes within the same 512-point bucket do not rebuild mixer content")
    precondition(counters.controls.mapValues(ObjectIdentifier.init) == beforeResizeControls,
                 "each pixel of live resize retains the existing faders and meters")
}
resizeMixer(to: 1025)
precondition(counters.contentEvaluations == beforeResizeEvaluations + 1,
             "crossing a viewport-height bucket refreshes mounted rows exactly once")
let expandedControls = counters.controls.mapValues(ObjectIdentifier.init)
precondition(expandedControls.count > beforeResizeControls.count,
             "the next height bucket mounts its additional incoming rows")
for (id, identity) in beforeResizeControls {
    precondition(expandedControls[id] == identity, "growing the viewport preserves every previously mounted control")
}
let expandedEvaluations = counters.contentEvaluations
for height: CGFloat in [1100, 1250, 1536, 1025] {
    resizeMixer(to: height)
    precondition(counters.contentEvaluations == expandedEvaluations && counters.controls.mapValues(ObjectIdentifier.init) == expandedControls,
                 "subsequent height changes inside the new bucket retain content and native identities")
}
resizeMixer(to: 900)
let shrunkControls = counters.controls.mapValues(ObjectIdentifier.init)
precondition(shrunkControls.count == expandedControls.count,
             "shrinking a bucket retains the bounded warm reserve for later scrolling")
for (id, identity) in beforeResizeControls {
    precondition(shrunkControls[id] == identity, "shrinking preserves every overlapping original control")
}
let beforeLargeResize = counters.contentEvaluations
resizeMixer(to: 2100)
precondition(counters.contentEvaluations == beforeLargeResize + 1,
             "a large resize crossing multiple buckets mounts its final viewport in one update")
let largeResizeControls = counters.controls.mapValues(ObjectIdentifier.init)
precondition(largeResizeControls.count > expandedControls.count,
             "a viewport larger than the original overscan creates all newly exposed controls")
for (id, identity) in beforeResizeControls {
    precondition(largeResizeControls[id] == identity, "large resizing also retains overlapping native controls")
}
resizeMixer(to: 2120)
precondition(counters.contentEvaluations == beforeLargeResize + 1 && counters.controls.mapValues(ObjectIdentifier.init) == largeResizeControls,
             "large viewports keep the same bucket behavior without repeated content evaluation")
MainActor.assumeIsolated {
    // Keep the tall-window reserve, then resize only the much smaller visible
    // viewport. Distant native controls must keep their last width until needed.
    window.setContentSize(CGSize(width: 800, height: 600))
    root.rootView = MixerLifecycleFixture(vertical: vertical, counters: counters, viewportHeight: 600, mixerWidth: 360)
    root.layoutSubtreeIfNeeded()
    let frozen = counters.controls.values.filter { abs($0.frame.width - 240) < 0.1 }
    precondition(frozen.count > 10, "resizing does not relayout the distant warm row reserve")
    precondition(counters.controls.values.contains { abs($0.frame.width - 360) < 0.1 }, "visible controls immediately receive the new width")
    let sidebar = SidebarScrollController()
    sidebar.attach(scroll, owner: root)
    sidebar.prepareScroll = { offset in
        let old = vertical.tiles.offset
        vertical.update(offset)
        return old != vertical.tiles.offset
    }
    let warmCreated = counters.created, warmDismantled = counters.dismantled
    for y: CGFloat in [511, 512, 1023, 2048, 8193, 8192, 1023, 511, 0] {
        let retainedBefore = counters.controls.mapValues(ObjectIdentifier.init)
        sidebar.scroll(to: y)
        let visible = (0..<200).filter { id in
            let top = 71 + CGFloat(id) * 72
            return top + 72 >= scroll.contentView.bounds.minY && top <= scroll.contentView.bounds.maxY
        }
        for id in visible {
            let view = counters.controls[id]!
            let frame = view.convert(view.bounds, to: scroll.documentView!)
            precondition(abs(frame.width - 360) < 0.1 && abs(frame.minY - (71 + CGFloat(id) * 72)) < 0.1,
                         "entering rows have current width and exact position before native scrolling returns, including bucket+511 and reversals")
        }
        precondition(counters.created == warmCreated && counters.dismantled == warmDismantled,
                     "revealing frozen row widths reuses their existing native controls")
        for (id, identity) in retainedBefore where counters.controls[id] != nil {
            precondition(ObjectIdentifier(counters.controls[id]!) == identity, "overlapping controls keep identity through width changes and scroll reversals")
        }
    }
}
print("TIMELINE_MIXER_OFFSCREEN_WIDTH_REUSE_AND_IMMEDIATE_REVEAL_OK")
private final class ActiveWidthFixtureState {
    let resize = SidebarResizeState()
    var committed: CGFloat = 240
}
private struct ActiveWidthFixture: View {
    let state: ActiveWidthFixtureState
    let vertical: TimelineVerticalScroll
    let counters: MixerLifecycleCounters
    var body: some View {
        SidebarResizeLayer(state: state.resize) { width in
            MixerLifecycleFixture(vertical: vertical, counters: counters, mixerWidth: width ?? state.committed,
                widthViewport: state.resize.limitsWidthToVisibleRows
                    ? CGRect(x: 0, y: vertical.offset, width: 0, height: 600) : nil)
        }
    }
}
MainActor.assumeIsolated {
    let state = ActiveWidthFixtureState(), position = TimelineVerticalScroll(), counts = MixerLifecycleCounters()
    let testWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    testWindow.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: ActiveWidthFixture(state: state, vertical: position, counters: counts))
    testWindow.contentView = host; host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded()
    let nativeScroll = descendants(GridNativeScrollView.self, in: host).first!
    let controller = SidebarScrollController(); controller.attach(nativeScroll, owner: host)
    controller.prepareScroll = { offset in
        let previous = position.tiles.offset
        position.update(offset)
        let restoreWidths = state.resize.includeWidthReserve()
        if restoreWidths { nativeScroll.window?.contentView?.layoutSubtreeIfNeeded() }
        return restoreWidths || previous != position.tiles.offset
    }
    let boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
        object: nativeScroll.contentView, queue: .main) { _ in
        let offset = nativeScroll.contentView.bounds.minY
        let moved = abs(position.offset - offset) > 0.001
        position.update(offset)
        if moved, state.resize.includeWidthReserve() { nativeScroll.window?.contentView?.layoutSubtreeIfNeeded() }
    }
    let created = counts.created
    var statePublications = 0
    let observation = state.resize.objectWillChange.sink { statePublications += 1 }
    func assertVisibleWidth(_ width: CGFloat) {
        for id in 0..<200 {
            let top = 71 + CGFloat(id) * 72
            guard top + 72 >= nativeScroll.contentView.bounds.minY && top <= nativeScroll.contentView.bounds.maxY else { continue }
            precondition(abs(counts.controls[id]!.frame.width - width) < 0.1,
                         "visible row \(id) width \(counts.controls[id]!.frame.width) expected \(width) at offset \(nativeScroll.contentView.bounds.minY) must be ready without RunLoop settling")
        }
        precondition(counts.created == created && counts.dismantled == 0,
                     "precise resize and reserve reconciliation never remount controls")
    }
    let identities = counts.controls.mapValues(ObjectIdentifier.init)
    state.resize.update(360); host.layoutSubtreeIfNeeded()
    assertVisibleWidth(360)
    let resizedRows = counts.controls.values.filter { abs($0.frame.width - 360) < 0.1 }.count
    precondition(resizedRows <= 9 && counts.controls.count > resizedRows * 2,
                 "active horizontal resize only relayouts actual visible rows, not the full scroll bucket")
    precondition(identities == counts.controls.mapValues(ObjectIdentifier.init))
    state.committed = 360; state.resize.update(nil); host.layoutSubtreeIfNeeded()
    precondition(!state.resize.limitsWidthToVisibleRows)
    let beforeOrdinaryScroll = statePublications
    for y: CGFloat in [20, 96, 255, 511] { controller.scroll(to: y); assertVisibleWidth(360) }
    precondition(statePublications == beforeOrdinaryScroll,
                 "ordinary native scrolling never republishes transient width state")
    controller.scroll(to: 0)
    state.resize.update(420); host.layoutSubtreeIfNeeded(); assertVisibleWidth(420)
    precondition(state.resize.limitsWidthToVisibleRows)
    controller.scroll(to: 256); assertVisibleWidth(420)
    precondition(!state.resize.limitsWidthToVisibleRows,
                 "first scrollbar movement during resize restores reserve widths even within the same 512-point bucket")
    state.committed = 420; state.resize.update(nil); host.layoutSubtreeIfNeeded()
    controller.scroll(to: 0)
    state.resize.update(460); host.layoutSubtreeIfNeeded()
    nativeScroll.contentView.scroll(to: CGPoint(x: 0, y: 256))
    assertVisibleWidth(460)
    precondition(!state.resize.limitsWidthToVisibleRows,
                 "a native wheel/bounds movement also restores widths synchronously during resize")
    state.committed = 460; state.resize.update(nil); host.layoutSubtreeIfNeeded()
    for y: CGFloat in [8193, 8192, 511, 0] { controller.scroll(to: y); assertVisibleWidth(460) }
    observation.cancel(); NotificationCenter.default.removeObserver(boundsObserver)
    testWindow.close()
}
print("TIMELINE_MIXER_PRECISE_RESIZE_FINAL_RECONCILIATION_AND_SIMULTANEOUS_SCROLL_OK")
private let variablePool = TimelineMixerRowPool<Int>()
let trackIDs = Array(0..<1000)
let variableHeights: [CGFloat] = trackIDs.map { $0 % 7 == 0 ? 240 : ($0 % 3 == 0 ? 128 : 64) }
var variableOffsets: [CGFloat] = []
var accumulatedHeight: CGFloat = 0
for height in variableHeights { variableOffsets.append(accumulatedHeight); accumulatedHeight += height }
var previousSlots: [Int: Int] = [:]
for y: CGFloat in [0, 512, 4096, 25000, 8192, 0] {
    let slots = variablePool.slots(ids: trackIDs, offsets: variableOffsets, heights: variableHeights,
                                   top: 71, visibleY: y, viewportHeight: 1024, pinned: [0])
    let indices = Set(slots.map(\.index))
    precondition(indices.count == slots.count && Set(slots.map(\.id)).count == slots.count,
                 "each track and native slot appears at most once")
    precondition(slots.count <= 43, "1000 variable-height tracks keep a bounded native pool")
    for index in trackIDs where mixerRowIsMounted(start: 71 + variableOffsets[index], height: variableHeights[index], visibleY: y, viewportHeight: 1024) {
        precondition(indices.contains(index), "every required variable-height row has a native slot")
    }
    let mapping = Dictionary(uniqueKeysWithValues: slots.map { ($0.index, $0.id) })
    for index in Set(previousSlots.keys).intersection(mapping.keys) {
        precondition(previousSlots[index] == mapping[index], "overlapping tracks retain their native slot identity")
    }
    precondition(mapping[0] != nil, "a row with an active pointer gesture stays bound even when scrolled offscreen")
    previousSlots = mapping
}
let reorderedIDs = Array(trackIDs.reversed())
private let reordered = variablePool.slots(ids: reorderedIDs, offsets: variableOffsets, heights: variableHeights,
                                   top: 71, visibleY: 0, viewportHeight: 1024, pinned: [0])
let reorderedMapping = Dictionary(uniqueKeysWithValues: reordered.map { (reorderedIDs[$0.index], $0.id) })
precondition(reorderedMapping[0] == previousSlots[0], "pinning follows track identity when track order changes")
precondition(variablePool.slots(ids: [], offsets: [], heights: [], top: 0, visibleY: 0, viewportHeight: 1024).isEmpty,
             "an empty project releases all row bindings")
print("TIMELINE_MIXER_REUSABLE_SLOTS_VARIABLE_HEIGHT_PINNING_AND_IMMEDIATE_SCROLL_OK")
NotificationCenter.default.removeObserver(observer)
print("TIMELINE_MIXER_VIEWPORT_HEIGHT_BUCKET_IDENTITY_AND_VISIBLE_COVERAGE_OK")
print("TIMELINE_MIXER_LIFECYCLE_OK rows=200 created=" + String(counters.created) + " contentEvaluations=" + String(counters.contentEvaluations) + " canvasBuckets=" + String(visitedBuckets.count) + " dismantled=" + String(counters.dismantled) + " detached=" + String(counters.detached))
window.close()

// Warm a full thin-track reserve, then expand. Offscreen geometry must stay
// dormant, while every track that scrolling can expose receives exact heights.
private let heightPool = TimelineMixerRowPool<Int>()
private let heightIDs = Array(0..<200)
private func heightSlots(_ height: CGFloat, visibleY: CGFloat = 0, pinned: Set<Int> = []) -> [TimelineMixerSlot] {
    heightPool.slots(ids: heightIDs, offsets: heightIDs.map { CGFloat($0) * height },
                    heights: Array(repeating: height, count: 200), top: 71,
                    visibleY: visibleY, viewportHeight: 1024, pinned: pinned)
}
private let thinSlots = heightSlots(24)
private let expandedSlots = heightSlots(240)
precondition(expandedSlots.count == thinSlots.count, "height changes retain warm controls")
private let resizedCount = expandedSlots.filter { $0.height != 24 }.count
precondition(resizedCount < 10 && expandedSlots.count > 100,
             "expanding a thin pool resizes visible controls, not a hundred dormant rows")
for y: CGFloat in [0, 512, 4096, 12800, 1024, 0] {
    let slots = heightSlots(240, visibleY: y)
    for slot in slots where 71 + CGFloat(slot.index) * 240 + 240 >= y && 71 + CGFloat(slot.index) * 240 <= y + 1536 {
        precondition(slot.height == 240, "every row in the scroll coverage has the current height before entering view")
    }
}
private let pinnedHeights = heightSlots(120, pinned: [100])
precondition(pinnedHeights.first { $0.index == 100 }?.height == 120,
             "an offscreen row with an active control gesture retains current geometry")
print("MIXER_HEIGHT_RESIZE_COVERAGE_OK updated=\(resizedCount) retained=\(expandedSlots.count)")
