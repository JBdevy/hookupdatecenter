let app = NSApplication.shared
let window = NSWindow(contentRect: NSRect(x:0,y:0,width:500,height:242), styleMask:[.borderless], backing:.buffered, defer:false)
private let view = FooterMixerScrollView(frame: NSRect(x:0,y:0,width:500,height:242))
window.contentView = view
view.update(content: AnyView(Color.black.frame(width:2000,height:226)), width:2000)
view.layoutSubtreeIfNeeded()
let scroll = view.subviews.compactMap { $0 as? NSScrollView }.first!
let bar = view.subviews.compactMap { $0 as? NSScroller }.first!
precondition(bar.frame.minY < scroll.frame.minY && bar.frame.width > bar.frame.height, "scrollbar occupies its own top row")
precondition(abs(bar.knobProportion - 0.25) < 0.01)
bar.doubleValue = 0.5; bar.sendAction(bar.action, to:bar.target)
precondition(abs(scroll.contentView.bounds.minX - 750) < 1, "top scrollbar moves exact horizontal position")
FooterScrollLayoutProbe.preparations = 0
bar.doubleValue = 0.51; bar.sendAction(bar.action, to:bar.target)
precondition(FooterScrollLayoutProbe.preparations == 1,
             "One scroll frame must prepare its strips once, including synchronous bounds notifications")
bar.doubleValue = 0.5; bar.sendAction(bar.action, to:bar.target)
view.smoothWheel(-40,target:scroll,horizontal:true)
let first = scroll.contentView.bounds.minX
precondition(abs(first - 764) < 1, "wheel begins immediately")
RunLoop.main.run(until: Date().addingTimeInterval(0.4))
precondition(abs(scroll.contentView.bounds.minX - 790) < 0.2, "release eases to requested distance without extra drift")
view.update(content: AnyView(Color.black.frame(width:600,height:226)), width:600)
view.layoutSubtreeIfNeeded()
precondition(scroll.contentView.bounds.minX <= 100.1, "removing tracks clamps the viewport")
print("MIXER_TOP_SCROLLBAR_AND_PHYSICAL_WHEEL_SHORT_EASE_OUT_OK")
var prepared: [Range<Int>] = []
view.update(width: 1000 * 153 + 7, stride: 153, count: 1000) { range in
    prepared.append(range)
    return AnyView(Color.black.frame(width: 1000 * 153 + 7, height: 226))
}
view.layoutSubtreeIfNeeded()
bar.doubleValue = 0.92; bar.sendAction(bar.action, to: bar.target)
let destination = Int(scroll.contentView.bounds.minX / 153)
precondition(prepared.contains(where: { $0.contains(destination) }), "destination channels must exist synchronously before the scrollbar exposes them")
precondition(prepared.last!.count < 40, "1000 tracks must not create 1000 channel controls")
bar.doubleValue = 0; bar.sendAction(bar.action, to: bar.target)
precondition(prepared.contains(where: { $0.contains(0) }), "fast reversal prepares the first channel before showing it")
print("MIXER_1000_TRACKS_SYNCHRONOUS_DESTINATION_PREPARATION_AND_BOUNDED_CHANNEL_COUNT_OK")

let document = scroll.documentView!
precondition(document.subviews.count <= 84, "visible channels plus warm cache remain bounded")
let existing = Set(document.subviews.map(ObjectIdentifier.init))
let before = scroll.contentView.bounds.minX
bar.doubleValue = (before + 10) / (document.frame.width - scroll.contentSize.width)
bar.sendAction(bar.action, to: bar.target)
precondition(Set(document.subviews.map(ObjectIdentifier.init)) == existing, "short drags preserve hosting views")
for fraction in [0.95, 0.1, 0.8, 0.0, 1.0] {
    bar.doubleValue = fraction; bar.sendAction(bar.action, to: bar.target)
    precondition(abs(scroll.contentView.bounds.minX - fraction * (document.frame.width - scroll.contentSize.width)) < 0.01, "thumb position is exact in both directions")
}
print("MIXER_HOST_REUSE_AND_EXACT_FAST_REVERSAL_OK")

view.update(width: 7, stride: 127, count: 0) { range in
    precondition(range.isEmpty)
    return AnyView(EmptyView())
}
view.layoutSubtreeIfNeeded()
precondition(scroll.documentView!.subviews.isEmpty && !bar.isEnabled, "no standard tracks leaves an empty mixer")

var versions = (0..<1000).map(UInt64.init)
var updatedStrips: [Int] = []
func refreshStrips() {
    view.update(width: 1000 * 153 + 7, stride: 153, count: 1000, versions: versions) { range in
        updatedStrips.append(contentsOf: range)
        return AnyView(Color.black.frame(width: 153, height: 226))
    }
    view.layoutSubtreeIfNeeded()
}
refreshStrips()
let retainedHosts = Set(scroll.documentView!.subviews.map(ObjectIdentifier.init))
updatedStrips.removeAll()
refreshStrips()
precondition(updatedStrips.isEmpty, "unchanged mixer metadata must not replace native hosting roots")
versions[2] = 2000
refreshStrips()
precondition(updatedStrips == [2], "one volume/pan edit replaces only its channel's hosting root")
precondition(Set(scroll.documentView!.subviews.map(ObjectIdentifier.init)) == retainedHosts,
             "scalar updates preserve channel controls and the current horizontal viewport")
updatedStrips.removeAll()
versions[999] = 3000
refreshStrips()
precondition(updatedStrips.isEmpty, "offscreen scalar changes never rebuild visible controls")
print("MIXER_SCALAR_EDITS_UPDATE_ONLY_CHANGED_HOST_WITHOUT_WINDOW_WIDE_RELAYOUT_OK")

// Shrinking after a wide viewport must not retain every formerly visible host.
// The channels that remain visible keep their existing control/state instances.
for width: CGFloat in [2200, 500, 1600, 420, 1800, 500] {
    let previous = Dictionary(uniqueKeysWithValues: scroll.documentView!.subviews.map { ($0.frame.minX, ObjectIdentifier($0)) })
    window.setContentSize(NSSize(width: width, height: 242))
    view.layoutSubtreeIfNeeded()
    let channels = scroll.documentView!.subviews
    let viewport = scroll.contentView.bounds
    let visible = channels.filter { $0.frame.intersects(viewport) }
    precondition(channels.count <= Int(ceil(viewport.width / 153)) + 6 + 64,
                 "a narrowed mixer bounds its visible hosts and retained reuse cache")
    precondition(!visible.isEmpty && visible.map(\.frame.maxX).max()! >= viewport.maxX,
                 "expanding must prepare newly exposed channels synchronously")
    for channel in visible {
        if let retained = previous[channel.frame.minX] {
            precondition(ObjectIdentifier(channel) == retained,
                         "back-and-forth resize must preserve controls that remain visible")
        }
    }
}
print("MIXER_WIDE_TO_NARROW_RESIZE_BOUNDS_HOST_COUNT_AND_PREPARES_REVEAL_OK")

private final class FooterFocusProbe: NSView {
    override var acceptsFirstResponder: Bool { true }
}
private struct FooterFocusFixture: NSViewRepresentable {
    func makeNSView(context: Context) -> FooterFocusProbe { FooterFocusProbe() }
    func updateNSView(_ view: FooterFocusProbe, context: Context) {}
}
private func footerFocusProbe(in view: NSView) -> FooterFocusProbe? {
    (view as? FooterFocusProbe) ?? view.subviews.compactMap { footerFocusProbe(in: $0) }.first
}
window.setContentSize(NSSize(width: 2200, height: 242))
view.layoutSubtreeIfNeeded()
var protectedChannels: Set<Int> = [23]
view.update(width: 8607, stride: 86, count: 100, retainStrip: { protectedChannels.contains($0) }) { _ in
    AnyView(FooterFocusFixture().frame(width: 83, height: 200))
}
view.layoutSubtreeIfNeeded()
private let focusedStrip = scroll.documentView!.subviews.first { $0.frame.minX == 20 * 86 }!
private let protectedStrip = scroll.documentView!.subviews.first { $0.frame.minX == 23 * 86 }!
private let focusProbe = footerFocusProbe(in: focusedStrip)!
precondition(window.makeFirstResponder(focusProbe))
window.setContentSize(NSSize(width: 860, height: 242)); view.layoutSubtreeIfNeeded()
precondition(focusedStrip.window === window && window.firstResponder === focusProbe,
             "a channel owning keyboard focus or an in-flight fader keeps its control instance when shrinking")
precondition(protectedStrip.window === window,
             "an offscreen channel with a pinned menu/button gesture must remain attached")
precondition(scroll.documentView!.subviews.count <= 16 + 64,
             "focus and pinning retain only their own channels beyond the bounded reuse cache")
window.makeFirstResponder(nil); protectedChannels.removeAll()
// Same viewport uses prepare's containment fast path, which must also release
// previously protected channels once the gesture or menu has ended.
bar.sendAction(bar.action, to: bar.target)
precondition(view.cachedStrips[20]?.view === focusedStrip && view.cachedStrips[23]?.view === protectedStrip,
             "finished focus/menu exceptions return to the bounded offscreen cache")
window.setContentSize(NSSize(width: 500, height: 242)); view.layoutSubtreeIfNeeded()
print("MIXER_SHRINK_PRESERVES_FOCUS_AND_PINNED_GESTURES_THEN_RELEASES_ONLY_EXCEPTIONS_OK")


// Real native meters inside the separately hosted, virtualized footer strips.
// Constant readings expose reveal failures hidden by a fresh audio update.
private struct FooterMeterFixture: View {
    let meter: TrackMeterLevel
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Color.clear.frame(height: max(0, geometry.size.height - 200))
                HStack(spacing: 2) {
                    Color.gray.frame(width: 27)
                    VerticalTrackMeter(meter: meter, showScale: false).frame(width: 8)
                }.frame(height: min(160, max(0, geometry.size.height - 40)))
                Text("Track").frame(height: 22)
            }.padding(4)
        }.frame(width: 83).padding(5)
    }
}
@MainActor private func nativeMeters(_ view: NSView) -> [NativeVerticalTrackMeterView] {
    (view as? NativeVerticalTrackMeterView).map { [$0] } ?? view.subviews.flatMap(nativeMeters)
}
@MainActor private func verifyFooterMeters() {
let meterModels = (0..<100).map { _ in TrackMeterLevel() }
for model in meterModels { model.update(left: 1, right: 0.5, elapsed: 1) }
view.update(width: 100 * 86 + 7, stride: 86, count: 100) { range in
    AnyView(FooterMeterFixture(meter: meterModels[range.lowerBound]))
}
window.orderFront(nil)
view.layoutSubtreeIfNeeded()
RunLoop.main.run(until: Date().addingTimeInterval(0.03))
func checkVisibleMeters(_ stage: String) {
    let visible = nativeMeters(view).filter { !$0.isHiddenOrHasHiddenAncestor && !$0.bounds.intersection($0.visibleRect).isEmpty }
    precondition(visible.count >= 4, "footer fixture needs multiple visible meters: \(stage)")
    for meter in visible {
        let backgrounds = meter.layer?.sublayers?.filter { $0.name?.hasPrefix("meter-background-") == true } ?? []
        let levels = meter.layer?.sublayers?.filter { $0.name?.hasPrefix("meter-level-") == true } ?? []
        if backgrounds.count != 2 || !backgrounds.allSatisfy({ $0.bounds.width > 0 && $0.bounds.height == meter.bounds.height }) {
            fputs("METER_GEOMETRY \(stage) frame=\(meter.frame) visible=\(meter.visibleRect) background=\(backgrounds.map(\.frame)) needsLayout=\(meter.needsLayout)\n", stderr)
        }
        precondition(backgrounds.count == 2 && backgrounds.allSatisfy { $0.bounds.width > 0 && $0.bounds.height == meter.bounds.height },
                     "footer meter backgrounds must remain visible: \(stage)")
        precondition(levels.count == 2 && levels.allSatisfy { $0.bounds.width > 0 && $0.bounds.height > 0 },
                     "cached signal must appear without another audio update: \(stage)")
    }
}
for fraction in [0.0, 0.7, 0.2, 1.0, 0.0] {
    bar.doubleValue = fraction; bar.sendAction(bar.action, to: bar.target)
    view.layoutSubtreeIfNeeded()
    checkVisibleMeters("horizontal scroll \(fraction)")
}
for height: CGFloat in [232, 400, 260, 232] {
    view.setFrameSize(NSSize(width: 500, height: height)); view.layoutSubtreeIfNeeded()
    checkVisibleMeters("resize \(height)")
}
for width: CGFloat in [500, 2200, 420, 1600, 500] {
    window.setContentSize(NSSize(width: width, height: 232)); view.layoutSubtreeIfNeeded()
    let channels = scroll.documentView!.subviews.compactMap { $0 as? FooterMixerHostingView }
    let mounted = channels.filter { !$0.isHidden }
    precondition(mounted.count >= 4 && mounted.allSatisfy { $0.frame.width == 93 && $0.frame.height == scroll.contentSize.height },
        "Resizing the window gives mounted channels their current viewport rectangle")
    if #available(macOS 13.3, *) {
        precondition(channels.allSatisfy { $0.safeAreaRegions.isEmpty },
            "Explicitly positioned channels do not inherit or propagate window safe-area sizing")
    }
    checkVisibleMeters("window width \(width)")
}
print("FOOTER_WINDOW_WIDTH_RESIZE_RETAINS_CHANNEL_RECTANGLES_WITHOUT_SAFE_AREA_LAYOUT_OK")
view.isHidden = true
for model in meterModels { model.reset(); model.update(left: 0.3, right: 0.4, elapsed: 1) }
view.isHidden = false; view.layoutSubtreeIfNeeded()
checkVisibleMeters("panel revealed")
window.orderOut(nil)
print("FOOTER_NATIVE_METERS_CONSTANT_SIGNAL_SCROLL_RESIZE_AND_REVEAL_OK")

}
MainActor.assumeIsolated { verifyFooterMeters() }

// The same native container is used by the docked and detached mixer. Master
// lives outside its scrolling document, including an empty song and resizes.
view.updateMaster(content: AnyView(Color.yellow.frame(width: 83 * 1.25).padding(5)), width: 83 * 1.25, version: 1)
view.update(width: 100 * 86 + 7, stride: 86, count: 100) { _ in
    AnyView(Color.green.frame(width: 83).padding(5))
}
window.setContentSize(NSSize(width: 640, height: 350)); view.layoutSubtreeIfNeeded()
private let master = view.subviews.compactMap { $0 as? FooterMixerHostingView }.first!
let fixedMaster = master.frame
precondition(abs((master.frame.width - 10) / 83 - 1.25) < 0.001, "Master is 25 percent wider than a track")
precondition(scroll.frame.minX == 83 * 1.25 + 3 && bar.frame.minX >= scroll.frame.minX,
             "the scrolling tracks and scrollbar begin to the right of Master")
for fraction in [0.0, 0.5, 1.0, 0.1] {
    bar.doubleValue = fraction; bar.sendAction(bar.action, to: bar.target)
    precondition(master.frame == fixedMaster && master.superview === view,
                 "horizontal scroll never moves or recycles Master")
}
for size in [NSSize(width: 360, height: 240), NSSize(width: 1100, height: 480)] {
    window.setContentSize(size); view.layoutSubtreeIfNeeded()
    precondition(master.frame.minX == 0 && master.frame.width == fixedMaster.width &&
                 master.frame.height == scroll.frame.height && bar.frame.minX >= scroll.frame.minX,
                 "docked/detached resizing retains Master and excludes it from the scrollbar")
}
view.update(width: 7, stride: 86, count: 0) { _ in AnyView(EmptyView()) }
view.layoutSubtreeIfNeeded()
precondition(master.superview === view && !master.isHidden && scroll.documentView!.subviews.isEmpty && !bar.isEnabled,
             "a song without tracks keeps the global Master visible")
print("MIXER_FIXED_MASTER_WIDER_THAN_TRACKS_AND_PRESERVED_ACROSS_SCROLL_RESIZE_EMPTY_SONG_OK")

view.update(width: 100 * 86 + 7, stride: 86, count: 100) { _ in
    AnyView(Color.green.frame(width: 83).padding(5))
}
view.updateMaster(content: AnyView(Color.yellow.frame(width: 83 * 1.25).padding(5)), width: 83 * 1.25, version: 2, right: true)
view.layoutSubtreeIfNeeded()
precondition(view.subviews.compactMap { $0 as? FooterMixerHostingView }.first === master,
             "Changing sides reuses the same fixed Master host")
for size in [NSSize(width: 640, height: 350), NSSize(width: 360, height: 240), NSSize(width: 1100, height: 480)] {
    window.setContentSize(size); view.layoutSubtreeIfNeeded()
    for fraction in [0.0, 0.5, 1.0] {
        bar.doubleValue = fraction; bar.sendAction(bar.action, to: bar.target)
        precondition(abs(master.frame.maxX - view.bounds.width) < 0.001 && master.frame.width == fixedMaster.width,
                     "Right-side Master stays pinned at every size and scroll position")
        precondition(scroll.frame.minX == 0 && scroll.frame.maxX <= master.frame.minX + 7.001 &&
                     bar.frame.maxX <= scroll.frame.maxX,
                     "Only tracks occupy the scrolling area on the left")
    }
}
view.update(width: 7, stride: 86, count: 0) { _ in AnyView(EmptyView()) }
view.layoutSubtreeIfNeeded()
precondition(!master.isHidden && master.frame.maxX == view.bounds.width && !bar.isEnabled)
view.updateMaster(content: AnyView(Color.yellow.frame(width: 83 * 1.25).padding(5)), width: 83 * 1.25, version: 3, right: false)
view.layoutSubtreeIfNeeded()
precondition(master.frame.minX == 0 && scroll.frame.minX == 83 * 1.25 + 3 && master.superview === view,
             "Returning to the left restores the original layout without recreating Master")
print("MIXER_MASTER_SIDE_SWITCH_PRESERVES_HOST_SCROLL_BOUNDS_RESIZE_AND_EMPTY_SONG_OK")

view.update(width: 1000 * 86 + 7, stride: 86, count: 1000) { _ in
    AnyView(Color.green.frame(width: 83).padding(5))
}
window.setContentSize(NSSize(width: 640, height: 350)); view.layoutSubtreeIfNeeded()
var scrollDurations: [Double] = []
for right in [false, true] {
    view.updateMaster(content: AnyView(Color.yellow.frame(width: 83 * 1.25).padding(5)), width: 83 * 1.25, version: right ? 5 : 4, right: right)
    view.layoutSubtreeIfNeeded()
    for fraction in [0.1, 0.5, 0.9, 0.11] {
        FooterScrollLayoutProbe.forced = 0
        let began = ProcessInfo.processInfo.systemUptime
        bar.doubleValue = fraction; bar.sendAction(bar.action, to: bar.target)
        scrollDurations.append(ProcessInfo.processInfo.systemUptime - began)
        let x = scroll.contentView.bounds.minX
        let visible = Int(x / 86)..<Int(ceil((x + scroll.contentSize.width) / 86))
        precondition(view.pendingStripLayout.isDisjoint(with: visible), "Every visible destination is laid out before scrolling")
        precondition(!view.pendingStripLayout.isEmpty, "Offscreen overscan is deferred beyond the input event")
        precondition(FooterScrollLayoutProbe.forced <= visible.count,
                     "Wheel/bar handling does not force layout of offscreen prefetched columns")
        precondition(abs(bar.doubleValue - fraction) < 0.002, "Virtualization does not reset the requested offset")
    }
}
print("MIXER_VISIBLE_DESTINATION_READY_OVERSCAN_DEFERRED_BOTH_MASTER_SIDES_OK max_ms=\(scrollDurations.max()! * 1000)")

private final class FooterWheelFixture: NSEvent {
    weak var fixtureWindow: NSWindow?
    var point = NSPoint.zero
    var dx: CGFloat = 0, dy: CGFloat = 0
    var flags: NSEvent.ModifierFlags = []
    var time: TimeInterval = 1
    var precise = true
    var eventPhase: NSEvent.Phase = [], inertialPhase: NSEvent.Phase = []
    override var timestamp: TimeInterval { time }
    override var phase: NSEvent.Phase { eventPhase }
    override var momentumPhase: NSEvent.Phase { inertialPhase }
    override var window: NSWindow? { fixtureWindow }
    override var locationInWindow: NSPoint { point }
    override var scrollingDeltaX: CGFloat { dx }
    override var scrollingDeltaY: CGFloat { dy }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var modifierFlags: NSEvent.ModifierFlags { flags }
}
window.orderFront(nil)
let slotScroll = NSScrollView(frame: NSRect(x: 5, y: 12, width: 80, height: 80))
let slotDocument = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 500))
slotScroll.documentView = slotDocument
master.addSubview(slotScroll)
private let wheel = FooterWheelFixture()
wheel.fixtureWindow = window
for right in [false, true] {
    view.updateMaster(content: AnyView(Color.yellow.frame(width: 83 * 1.25).padding(5)), width: 83 * 1.25, version: 5, right: right)
    view.layoutSubtreeIfNeeded()
    // A nested list may contain wide content, but it never owns horizontal input.
    slotScroll.frame = NSRect(x: 5, y: 12, width: 80, height: 80)
    slotScroll.contentView.scroll(to: .zero)
    bar.doubleValue = 0.3; bar.sendAction(bar.action, to: bar.target)
    wheel.point = slotScroll.contentView.convert(NSPoint(x: 30, y: 30), to: nil)
    wheel.dx = -30; wheel.dy = -2
    let trackBefore = scroll.contentView.bounds.minX
    let fxBefore = slotScroll.contentView.bounds.origin
    precondition(view.routeWheel(wheel))
    precondition(scroll.contentView.bounds.minX > trackBefore && scroll.contentView.bounds.minX <= trackBefore + 30 && slotScroll.contentView.bounds.origin == fxBefore,
                 "Horizontal gestures over FX move whole channels, never the slot document")
    wheel.dx = -2; wheel.dy = 30
    let verticalBefore = scroll.contentView.bounds.minX
    precondition(view.routeWheel(wheel))
    precondition(slotScroll.contentView.bounds.minY > fxBefore.y && slotScroll.contentView.bounds.minX == 0 &&
                 scroll.contentView.bounds.minX == verticalBefore,
                 "Vertical gestures inside overflowing FX only move that list vertically")
    wheel.point = master.convert(NSPoint(x: 30, y: 150), to: nil)
    wheel.dx = 0; wheel.dy = -24
    let slotOffset = slotScroll.contentView.bounds.origin
    precondition(view.routeWheel(wheel))
    precondition(scroll.contentView.bounds.minX > verticalBefore && scroll.contentView.bounds.minX <= verticalBefore + 24 && slotScroll.contentView.bounds.origin == slotOffset,
                 "Empty space outside the FX viewport scrolls channels without moving slots")
    wheel.point = slotScroll.contentView.convert(NSPoint(x: 30, y: 30), to: nil)
    wheel.flags = .shift
    let shiftedBefore = scroll.contentView.bounds.minX
    precondition(view.routeWheel(wheel))
    precondition(scroll.contentView.bounds.minX == shiftedBefore && slotScroll.contentView.bounds.origin == slotOffset,
                 "A short Shift-wheel is consumed without moving channels, FX slots or changing mode")
    wheel.flags = []
}
print("MIXER_WHEEL_FX_VERTICAL_ONLY_INSIDE_VISIBLE_VIEWPORT_HORIZONTAL_AND_EMPTY_SPACE_ROUTE_TO_TRACKS_OK")

// Long precise gestures remain bounded, immediately reversible, and queue no tail.
bar.doubleValue = 0.25; bar.sendAction(bar.action, to: bar.target)
wheel.point = master.convert(NSPoint(x: 30, y: 150), to: nil)
wheel.flags = []; wheel.precise = true; wheel.dx = 0; wheel.dy = 0; wheel.time = 5
precondition(view.routeWheel(wheel))
let capStart = scroll.contentView.bounds.minX
wheel.dy = -10000
for index in 1...120 { wheel.time = 5 + Double(index)/120; precondition(view.routeWheel(wheel)) }
let capTravel = scroll.contentView.bounds.minX - capStart
precondition(capTravel > 0 && capTravel <= NativeMixerScrollVelocity.maximum(viewport: scroll.contentSize.width) + 1,
             "A long horizontal flick must obey the time-based viewport speed limit")
wheel.dy = 1; wheel.time = 6.02
let capEnd = scroll.contentView.bounds.minX
precondition(view.routeWheel(wheel) && abs(scroll.contentView.bounds.minX - (capEnd-1)) < 0.01,
             "Precise correction after a long flick cannot wait behind excess travel")
let capRest = scroll.contentView.bounds.minX
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
precondition(abs(scroll.contentView.bounds.minX-capRest) <= 1/window.backingScaleFactor,
             "Precise capped gestures must not replay dropped movement later")
print("HOZ_LONG_FLICK_VELOCITY_CAP_IMMEDIATE_REVERSE_AND_NO_QUEUED_MOVEMENT_OK")

// Native routing is shared by docked and detached mixers, including master.
// Deliberate Shift input belongs to the panel before any child slider sees it.
var requestedModes: [Bool] = []
view.setSlotsOnly = { requestedModes.append($0) }
wheel.point = master.convert(NSPoint(x: 30, y: 150), to: nil)
wheel.flags = .shift; wheel.precise = false; wheel.dx = 0; wheel.dy = 1
let initialHorizontal = scroll.contentView.bounds.minX
let initialSlotPosition = slotScroll.contentView.bounds.origin
for n in 0..<1 {
    wheel.time = 10 + Double(n) * 0.05
    precondition(view.routeWheel(wheel) && requestedModes.isEmpty,
                 "A single physical notch must not trigger the two-notch gesture")
}
wheel.time = 10.2; precondition(view.routeWheel(wheel))
precondition(requestedModes == [true], "Shift-wheel up switches to FX/instrument slots only")
for n in 1...20 { wheel.time = 10.2 + Double(n) * 0.05; precondition(view.routeWheel(wheel)) }
precondition(requestedModes == [true], "Holding the same gesture never repeats the action")
precondition(scroll.contentView.bounds.minX == initialHorizontal && slotScroll.contentView.bounds.origin == initialSlotPosition,
             "All Shift events are swallowed before child scrolling or mixer controls")
wheel.dy = -1
for n in 0..<3 { wheel.time = 12 + Double(n) * 0.05; precondition(view.routeWheel(wheel)) }
precondition(requestedModes == [true, false], "Shift-wheel down restores normal layout")
wheel.precise = true; wheel.dy = 10_000; wheel.time = 13
precondition(view.routeWheel(wheel) && requestedModes.count == 2,
             "One accelerated spike is limited to forty points and cannot change the layout")
wheel.inertialPhase = .changed
for n in 1...10 { wheel.time = 13 + Double(n) * 0.01; precondition(view.routeWheel(wheel)) }
precondition(requestedModes.count == 2, "Momentum never contributes to the mode gesture")
wheel.inertialPhase = []; wheel.time = 14; wheel.dy = 60
precondition(view.routeWheel(wheel))
precondition(requestedModes.count == 2, "The idle gap discarded the old partial spike")
wheel.time = 14.1; precondition(view.routeWheel(wheel))
precondition(requestedModes == [true, false, true], "Precise deltas reach the same threshold")
// Native Shift wheels can be axis-remapped by AppKit. Keep the physical intent.
wheel.dy = 0; wheel.dx = -1; wheel.precise = false
for n in 0..<3 { wheel.time = 15 + Double(n) * 0.05; precondition(view.routeWheel(wheel)) }
precondition(requestedModes == [true, false, true, false])
wheel.dx = 0; wheel.dy = 1; wheel.time = 16
precondition(view.routeWheel(wheel))
wheel.point = NSPoint(x: -30, y: -30); wheel.time = 16.1
precondition(!view.routeWheel(wheel), "The gesture only belongs to the hovered mixer")
wheel.point = master.convert(NSPoint(x: 30, y: 150), to: nil)
for n in 0..<1 { wheel.time = 16.2 + Double(n) * 0.05; precondition(view.routeWheel(wheel)) }
precondition(requestedModes.count == 4, "Leaving the panel resets a partial gesture")
wheel.time = 16.4; precondition(view.routeWheel(wheel))
precondition(requestedModes.count == 5)
view.isHidden = true; wheel.time = 17
precondition(!view.routeWheel(wheel), "A hidden/detached closed panel does not capture wheel input")
view.isHidden = false; wheel.flags = [.shift, .command]
precondition(!view.routeWheel(wheel), "Other command gestures are not intercepted")
wheel.flags = []
window.orderOut(nil)
print("MIXER_SHIFT_WHEEL_THRESHOLD_DIRECTIONS_MOMENTUM_HOVER_AND_CHILD_CONSUMPTION_OK")

// Real Quartz/AppKit conversion verifies the physical line-wheel normalization,
// independently of the event fixture used to target the native view.
for lines: Int32 in [1, -1, 3] {
    let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                     wheel1: lines, wheel2: 0, wheel3: 0)!
    let event = NSEvent(cgEvent: cg)!
    precondition(!event.hasPreciseScrollingDeltas && event.scrollingDeltaY == CGFloat(lines))
}
print("MIXER_PHYSICAL_LINE_WHEEL_QUARTZ_APPKIT_NORMALIZATION_OK")

private var modeGesture = FooterMixerModeGesture()
func modeStep(_ delta: CGFloat, _ time: TimeInterval, precise: Bool = false) -> Bool? {
    modeGesture.consume(delta: delta, precise: precise, timestamp: time, momentum: false)
}
precondition(modeStep(1, 1) == nil && modeStep(-1, 1.1) == nil)
precondition(modeStep(-1, 1.2) == false, "Two notches after reversing complete the gesture")
modeGesture.reset()
for time in [1.3, 1.4, 1.5, 1.6, 1.7] { precondition(modeStep(1, time) == nil) }
precondition(modeStep(1, 1.9) == nil)
precondition(modeStep(1, 2) == true, "Cooldown survives a released Shift or reversed gesture")
modeGesture.reset()
precondition(modeStep(4, 4) == nil && modeStep(4, 4.7) == nil)
precondition(modeStep(4, 4.8) == true, "A gap over 0.6 seconds discards incomplete progress")
print("MIXER_MODE_GESTURE_REVERSAL_IDLE_GAP_RESET_AND_COOLDOWN_OK")
for height: CGFloat in [80, 160, 242, 255, 350, 600] {
    let normal = FooterMixerStripLayout(height: height, slotsOnly: false)
    let compact = FooterMixerStripLayout(height: height, slotsOnly: true)
    let icons = FooterMixerStripLayout(height: height, slotsOnly: true, iconHeight: 30)
    precondition(icons.controlsHeight == 0 && icons.slotsHeight == max(0, height - 78),
                 "The icon stays below the name when only slots are shown")
    precondition(normal.controlsHeight == min(205, max(100, height - 48)))
    precondition(normal.slotsHeight == max(0, height - 48 - normal.controlsHeight),
                 "Controls and slots reserve the full name and number band")
    precondition(compact.controlsHeight == 0 && compact.slotsHeight == max(0, height - 48),
                 "Slots-only mode reserves only the fixed name/number band and the existing outer padding")
}
print("MIXER_SLOTS_ONLY_FULL_AVAILABLE_HEIGHT_NORMAL_GEOMETRY_UNCHANGED_OK")

precondition(FooterMixerStripLayout(height: 239, slotsOnly: false).slotsHeight == 0,
             "The minimum docked height must hide all slots")
for count in [0, 1, 2, 8] {
    for height in stride(from: CGFloat(0), through: 500, by: 1) {
        let sections = FooterSlotSectionsLayout(height: height, outputCount: count)
        precondition(sections.pluginsHeight + sections.outputsHeight + sections.dividerHeight == height)
        precondition(sections.outputsHeight == 0 || sections.pluginsHeight >= 63)
    }
}
private let tallSections = FooterSlotSectionsLayout(height: 500, outputCount: 8)
precondition(tallSections.pluginsHeight > 3 * 21 && tallSections.outputsHeight == 40)
print("MIXER_MINIMUM_HIDES_SLOTS_PLUGINS_GROW_UNBOUNDED_OUTPUTS_RESERVE_SCROLL_VIEWPORT_OK")

slotScroll.removeFromSuperview()
private final class FooterWindowLifecycleProbe: NSView {
    static var attachments = 0
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { Self.attachments += 1 }
    }
}
private struct FooterWindowLifecycleFixture: NSViewRepresentable {
    func makeNSView(context: Context) -> FooterWindowLifecycleProbe { FooterWindowLifecycleProbe() }
    func updateNSView(_ view: FooterWindowLifecycleProbe, context: Context) {}
}
var cacheVersions = (0..<1000).map { UInt64($0 + 100) }
var cacheMakes: [Int: Int] = [:]
func updateCacheFixture(count: Int = 1000) {
    view.update(width: CGFloat(count) * 86 + 7, stride: 86, count: count, versions: Array(cacheVersions.prefix(count))) { range in
        cacheMakes[range.lowerBound, default: 0] += 1
        return AnyView(Text("Channel \(range.lowerBound) version \(cacheVersions[range.lowerBound])").frame(width: 83).padding(5)
            .background(FooterWindowLifecycleFixture()))
    }
}
func cacheMove(_ index: Int) {
    bar.doubleValue = Double(index * 86) / max(1, Double(scroll.documentView!.frame.width - scroll.contentSize.width))
    bar.sendAction(bar.action, to: bar.target)
}
window.orderFront(nil)
updateCacheFixture(); view.layoutSubtreeIfNeeded(); cacheMove(0)
private let initialFirst = scroll.documentView!.subviews.compactMap { $0 as? FooterMixerHostingView }.first { $0.frame.minX == 0 }!
let initialBuilds = cacheMakes[0]!
cacheMove(20)
precondition(view.cachedStrips[0]?.view === initialFirst && initialFirst.window === window && initialFirst.visibleRect.isEmpty && initialFirst.isHidden,
             "Offscreen hosts preserve their window environment while the clip excludes their drawing")
let cachedHeight = initialFirst.frame.height
let previousSize = view.frame.size
view.setFrameSize(NSSize(width: previousSize.width, height: previousSize.height + 60)); view.layoutSubtreeIfNeeded()
precondition(initialFirst.frame.height == cachedHeight, "Height drag must not resize hidden cached channels")
let attachmentsBeforeReversal = FooterWindowLifecycleProbe.attachments
cacheMove(0)
precondition(FooterWindowLifecycleProbe.attachments == attachmentsBeforeReversal,
             "Warm reversal must not detach/reattach native controls or invalidate their window environment")
precondition(initialFirst.superview === scroll.documentView && cacheMakes[0] == initialBuilds,
             "Warm reversal reuses the same host and SwiftUI root without rebuilding its controls")
precondition(initialFirst.frame.height == scroll.contentSize.height, "A cached channel must adopt the current height when revealed")
view.setFrameSize(previousSize); view.layoutSubtreeIfNeeded()
cacheMove(20)
cacheVersions[0] = 90001
updateCacheFixture()
cacheMove(0)
precondition(initialFirst.superview === scroll.documentView && cacheMakes[0] == initialBuilds + 1,
             "Cached roots validate the latest identity/FX version on normal scroll after offscreen edits")
FooterScrollLayoutProbe.forced = 0
cacheMove(20); cacheMove(0)
precondition(FooterScrollLayoutProbe.forced == 0,
             "scrolling back to ready cached channels must not synchronously relayout their hosting trees")
for index in stride(from: 0, to: 900, by: 20) { cacheMove(index) }
precondition(view.cachedStrips.count <= 64 && view.cachedStrips.values.allSatisfy { $0.view.window === window && $0.view.visibleRect.isEmpty && $0.view.isHidden },
             "1000-track browsing retains at most 64 clipped cache entries")
updateCacheFixture(count: 0)
precondition(view.cachedStrips.isEmpty, "Deleting the track list releases detached roots")
window.orderOut(nil)
print("MIXER_WARM_REVERSAL_REUSES_ATTACHED_BOUNDED_HOSTS_AND_INVALIDATES_OFFSCREEN_VERSIONS_OK")

// The expensive case is inserting a copied track ahead of existing channels.
// Their controls must move with their tracks instead of being recreated by index.
var insertionIDs = (0..<32).map { _ in UUID() }
var insertionVersions = (0..<32).map { UInt64($0 + 1) }
var insertionBuilds: [UUID: Int] = [:]
func updateInsertionFixture() {
    view.update(width: CGFloat(insertionIDs.count) * 86 + 7, stride: 86, count: insertionIDs.count,
                versions: insertionVersions, identifiers: insertionIDs) { range in
        let id = insertionIDs[range.lowerBound]
        insertionBuilds[id, default: 0] += 1
        return AnyView(Text(id.uuidString).frame(width: 83).padding(5).background(FooterWindowLifecycleFixture()))
    }
}
window.orderFront(nil)
updateInsertionFixture(); cacheMove(0); view.layoutSubtreeIfNeeded()
private let movedID = insertionIDs[3]
private let movedHost = scroll.documentView!.subviews.compactMap { $0 as? FooterMixerHostingView }.first { !$0.isHidden && $0.frame.minX == 3 * 86 }!
let movedBuilds = insertionBuilds[movedID]!
let originalIDs = insertionIDs
insertionIDs.insert(UUID(), at: 1); insertionVersions.insert(10000, at: 1)
updateInsertionFixture(); view.layoutSubtreeIfNeeded()
precondition(movedHost.superview === scroll.documentView && !movedHost.isHidden && insertionBuilds[movedID] == movedBuilds,
             "Inserting a track repositions the existing channel without rebuilding its controls")
precondition(movedHost.frame.minX == 4 * 86 && movedHost.window === window,
             "Retained channels immediately occupy their new visible positions")
insertionIDs = originalIDs; insertionVersions.remove(at: 1)
updateInsertionFixture(); view.layoutSubtreeIfNeeded()
precondition(movedHost.superview === scroll.documentView && movedHost.frame.minX == 3 * 86 && insertionBuilds[movedID] == movedBuilds,
             "Undoing insertion restores the same existing channel and its local state")
view.update(width: 7, stride: 86, count: 0, identifiers: []) { _ in AnyView(EmptyView()) }
window.orderOut(nil)
print("MIXER_TRACK_INSERTION_AND_UNDO_PRESERVE_EXISTING_HOSTS_CONTROL_ROOTS_AND_REAL_GEOMETRY_OK")

// Enlarging the docked mixer adds FX space without proposing a new size to
// the lower controls. This is the path that used to reflow every fader per pixel.
private let heightStrip = FooterMixerStripGeometryView(frame: NSRect(x: 0, y: 0, width: 83, height: 254))
var lowerRootBuilds = 0
heightStrip.update(slotsOnly: false, iconHeight: 0, slots: AnyView(Color.clear), footer: { height in
    lowerRootBuilds += 1
    return AnyView(VStack(spacing: 0) { Color.red.frame(height: height); Text("Track").frame(height: FooterMixerStripLayout.labelHeight) })
})
heightStrip.layoutSubtreeIfNeeded()
let lowerHost = heightStrip.subviews[1]
let lowerSize = lowerHost.frame.size
for height in 255...640 {
    heightStrip.setFrameSize(NSSize(width: 83, height: height)); heightStrip.layoutSubtreeIfNeeded()
    precondition(lowerHost.frame.size == lowerSize, "Mixer height drag remeasured the fixed controls")
    precondition(abs(lowerHost.frame.maxY - CGFloat(height - 4)) < 0.01, "Track name must remain at the bottom of the channel")
    precondition(heightStrip.subviews[0].frame.maxY == lowerHost.frame.minY, "Slots and controls must remain adjacent")
}
precondition(lowerRootBuilds == 1, "Increasing mixer height rebuilt the control hierarchy")
heightStrip.update(slotsOnly: true, iconHeight: 30, slots: AnyView(Color.clear), footer: { height in
    precondition(height == 0, "Slots-only must hide the control area")
    return AnyView(Text("Track icon").frame(height: FooterMixerStripLayout.labelHeight + 30))
})
heightStrip.layoutSubtreeIfNeeded()
precondition(lowerHost.frame.height == FooterMixerStripLayout.labelHeight + 30 && lowerHost.frame.maxY == heightStrip.bounds.height - 4,
             "Slots-only must preserve the lower name/icon row")
print("FOOTER_MIXER_HEIGHT_DRAG_FIXED_CONTROLS_400_STEPS_AND_SLOTS_ONLY_OK")

private let slotsViewport = FooterEffectSlotsViewport(frame: NSRect(x: 0, y: 0, width: 75, height: 40))
slotsViewport.update(content: AnyView(VStack(spacing: 2) { ForEach(0..<8) { Text("FX \($0)").frame(height: 19) } }), height: 166)
slotsViewport.layoutSubtreeIfNeeded()
private let fxScroll = slotsViewport.subviews.compactMap { $0 as? NSScrollView }.first!
private let fxDocument = fxScroll.documentView!
private let fxRoot = fxDocument.subviews.first!
let fixedFXFrame = fxRoot.frame
for height in 41...300 {
    slotsViewport.setFrameSize(NSSize(width: 75, height: height)); slotsViewport.layoutSubtreeIfNeeded()
    precondition(fxRoot.frame == fixedFXFrame && fxDocument.frame == fixedFXFrame,
                 "Mixer expansion must only resize the FX viewport, leaving slot content geometry fixed")
    precondition(fxScroll.frame == slotsViewport.bounds, "FX viewport must fill the channel's slot area")
}
slotsViewport.setFrameSize(NSSize(width: 75, height: 40)); slotsViewport.layoutSubtreeIfNeeded()
fxScroll.contentView.scroll(to: NSPoint(x: 0, y: 80)); fxScroll.reflectScrolledClipView(fxScroll.contentView)
precondition(fxScroll.contentView.bounds.minY == 80, "Native FX viewport must retain vertical scrolling")
print("FOOTER_FX_VIEWPORT_RESIZE_PRESERVES_FIXED_SLOT_DOCUMENT_AND_SCROLLING_OK")

// The production FX/output divider changes native viewport frames without
// reevaluating every slot button per pixel, including a floating window.
private enum SlotSectionJournal { static var bodies = 0; static var clicks: [String] = [] }
private final class SlotSectionButton: NSButton {
    var role = "", language = ""
    var dark = false
    var testAction: () -> Void = {}
}
private struct SlotSectionButtonProbe: NSViewRepresentable {
    let role: String, revision: Int
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    func makeNSView(context: Context) -> SlotSectionButton { SlotSectionButton() }
    func updateNSView(_ view: SlotSectionButton, context: Context) {
        view.role = role; view.title = role; view.language = locale.identifier; view.dark = colorScheme == .dark
        view.testAction = { SlotSectionJournal.clicks.append("\(role)-\(revision)") }
    }
}
private struct SlotSectionContent: View {
    let role: String, count: Int, revision: Int
    var body: some View {
        let _ = { SlotSectionJournal.bodies += 1 }()
        VStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { index in
                SlotSectionButtonProbe(role: "\(role)\(index)", revision: revision).frame(height: 19)
            }
        }
    }
}
private func slotSectionButtons(_ view: NSView) -> [SlotSectionButton] {
    (view as? SlotSectionButton).map { [$0] } ?? view.subviews.flatMap(slotSectionButtons)
}
for detached in [false, true] {
    let sections = FooterSlotSectionsView(frame: CGRect(x: 0, y: 0, width: 75, height: 120))
    let sectionWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 75, height: 120),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    sectionWindow.isReleasedWhenClosed = false
    let container = NSView(frame: sections.frame)
    if detached { sectionWindow.contentView = sections } else { container.addSubview(sections); sectionWindow.contentView = container }
    func update(_ revision: Int, outputs: Int = 4) {
        let locale = Locale(identifier: revision == 0 ? "en" : "pt_BR")
        sections.update(plugins: AnyView(SlotSectionContent(role: "FX", count: 8, revision: revision)
            .environment(\.locale, locale).environment(\.colorScheme, revision == 0 ? .dark : .light)),
            pluginsHeight: 166, outputs: AnyView(SlotSectionContent(role: "OUT", count: outputs, revision: revision)
                .environment(\.locale, locale).environment(\.colorScheme, revision == 0 ? .dark : .light)), outputCount: outputs)
        sections.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03)); sections.layoutSubtreeIfNeeded()
    }
    update(0)
    let slots = sections.subviews.compactMap { $0 as? FooterEffectSlotsViewport }
    let pluginScroll = slots[0].subviews.compactMap { $0 as? NSScrollView }.first!
    let outputScroll = slots[1].subviews.compactMap { $0 as? NSScrollView }.first!
    let pluginDocument = pluginScroll.documentView!, outputDocument = outputScroll.documentView!
    let pluginFrame = pluginDocument.frame, outputFrame = outputDocument.frame
    let initialBodies = SlotSectionJournal.bodies
    let buttons = slotSectionButtons(sections)
    precondition(buttons.count == 12, "All eight plugins and four outputs must exist")
    for height in stride(from: 70, through: 360, by: 1) {
        if detached { sectionWindow.setContentSize(NSSize(width: 75, height: height)) }
        else { sections.setFrameSize(NSSize(width: 75, height: height)) }
        sections.layoutSubtreeIfNeeded()
        let expected = FooterSlotSectionsLayout(height: CGFloat(height), outputCount: 4)
        precondition(slots[0].frame.height == expected.pluginsHeight && slots[1].frame.height == expected.outputsHeight)
        precondition(slots[1].frame.minY == expected.pluginsHeight + expected.dividerHeight && slots[1].isHidden == (expected.outputsHeight == 0))
        precondition(pluginDocument.frame == pluginFrame && outputDocument.frame == outputFrame,
                     "FX and output documents must remain fixed while their viewports change")
    }
    precondition(SlotSectionJournal.bodies == initialBodies,
                 "Native height changes must not rebuild plugin/output button roots")
    sections.setFrameSize(NSSize(width: 75, height: 120)); sections.layoutSubtreeIfNeeded()
    pluginScroll.contentView.scroll(to: CGPoint(x: 0, y: 50))
    outputScroll.contentView.scroll(to: CGPoint(x: 0, y: 20))
    sections.layoutSubtreeIfNeeded()
    precondition(pluginScroll.contentView.bounds.minY == 50 && outputScroll.contentView.bounds.minY == 20,
                 "The FX and output lists keep independent scroll positions")
    sections.setFrameSize(NSSize(width: 75, height: 70)); sections.layoutSubtreeIfNeeded()
    precondition(slots[1].isHidden && slots[1].visibleRect.isEmpty,
                 "Below the output threshold no hidden routing button has a visible hit area")
    sections.setFrameSize(NSSize(width: 75, height: 120)); sections.layoutSubtreeIfNeeded()
    precondition(!slots[1].isHidden && outputScroll.contentView.bounds.minY == 20,
                 "Hiding and restoring the routing viewport retains its document and scroll position")
    update(1)
    let current = slotSectionButtons(sections)
    precondition(Set(current.map(ObjectIdentifier.init)) == Set(buttons.map(ObjectIdentifier.init)))
    precondition(current.allSatisfy { $0.language == "pt_BR" && !$0.dark })
    current.first!.testAction()
    precondition(SlotSectionJournal.clicks.last!.hasSuffix("-1"), "An update at the same height must refresh the action")
    update(2, outputs: 0)
    precondition(slots[1].isHidden && slots[0].frame.height == sections.bounds.height,
                 "No outputs gives the full available space to plugins")
    update(3, outputs: 4)
    precondition(!slots[1].isHidden && slotSectionButtons(sections).count == 12,
                 "Adding outputs while the panel is open restores the live routing controls")
    sectionWindow.close()
}
print("FOOTER_NATIVE_FX_OUTPUT_DIVIDER_DOCKED_FLOATING_HEIGHTS_FIXED_DOCUMENTS_SCROLL_ACTIONS_ENVIRONMENT_WITHOUT_ROOT_REBUILDS_OK")

private let stableChannelHost = FooterMixerHostingView(rootView: AnyView(
    FooterMixerStripGeometry(slotsOnly: false, iconHeight: 0, selected: true, slots: AnyView(Color.clear),
        footer: { AnyView(Color.clear.frame(height: $0 + FooterMixerStripLayout.labelHeight)) }).padding(5)))
stableChannelHost.frame = NSRect(x: 0, y: 0, width: 93, height: 240)
window.contentView!.addSubview(stableChannelHost); stableChannelHost.layoutSubtreeIfNeeded()
private func findChannelGeometry(_ root: NSView) -> FooterMixerStripGeometryView? {
    if let geometry = root as? FooterMixerStripGeometryView { return geometry }
    return root.subviews.lazy.compactMap(findChannelGeometry).first
}
private let stableGeometry = findChannelGeometry(stableChannelHost)!
for height in 241...500 {
    stableChannelHost.setChannelFrame(NSRect(x: 0, y: 0, width: 93, height: height))
    stableChannelHost.layoutSubtreeIfNeeded()
    precondition(stableChannelHost.frame.height == 724, "Channel decorations must keep a fixed SwiftUI size proposal")
    precondition(abs(stableGeometry.subviews[1].frame.maxY - CGFloat(height - 14)) < 0.01,
                 "Fixed outer decoration size must not displace the channel's lower controls")
}
stableChannelHost.removeFromSuperview()
print("FOOTER_CHANNEL_FIXED_HOST_PROPOSAL_AND_EXACT_NATIVE_VISIBLE_GEOMETRY_OK")

// Exercise the actual nested native channel structure on its first reveal.
// No later run-loop tick or parent layout is allowed to repair blank controls.
private struct RevealControl: NSViewRepresentable {
    func makeNSView(context: Context) -> NSButton { NSButton(title: "Reveal control", target: nil, action: nil) }
    func updateNSView(_ view: NSButton, context: Context) {}
}
private func revealButtons(_ view: NSView) -> [NSButton] {
    (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(revealButtons)
}
view.update(width: 300 * 86 + 7, stride: 86, count: 300) { _ in
    AnyView(FooterMixerStripGeometry(slotsOnly: false, iconHeight: 0, selected: false,
        slots: AnyView(Color.gray), footer: { height in
            AnyView(VStack { RevealControl().frame(height: 24); Spacer(minLength: 0) }.frame(height: height + FooterMixerStripLayout.labelHeight))
        }).frame(width: 83).padding(5))
}
view.layoutSubtreeIfNeeded()
for fraction in [0.75, 0.1, 0.95, 0.0, 0.6] {
    bar.doubleValue = fraction; bar.sendAction(bar.action, to: bar.target)
    let viewport = scroll.contentView.bounds
    let visible = scroll.documentView!.subviews.compactMap { $0 as? FooterMixerHostingView }
        .filter { !$0.isHidden && $0.frame.intersects(viewport) }
    precondition(!visible.isEmpty)
    for channel in visible {
        precondition(channel.frame.height >= 724, "first reveal must apply the native channel viewport before scrolling")
        let buttons = revealButtons(channel)
        precondition(buttons.count == 1 && buttons[0].frame.height > 0 && buttons[0].frame.width > 0,
                     "the nested footer controls must already exist with nonzero geometry")
    }
}
print("FOOTER_FIRST_REVEAL_COMMITS_NESTED_CONTROLS_BEFORE_CLIP_MOVES_OK")

private let opening = FooterMixerScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 273))
func openingContent(_ range: Range<Int>) -> AnyView {
    AnyView(FooterMixerStripGeometry(slotsOnly: false, iconHeight: 0, selected: false,
        slots: AnyView(Color.gray), footer: { height in
            AnyView(VStack { RevealControl().frame(height: 24); Spacer(minLength: 0) }.frame(height: height + FooterMixerStripLayout.labelHeight))
        }).frame(width: 83).padding(5))
}
opening.update(width: 100 * 86 + 7, stride: 86, count: 100, makeContent: openingContent)
opening.layoutSubtreeIfNeeded()
precondition(!opening.pendingStripLayout.isEmpty, "off-window roots must retain pending preparation")
let openingWindow = NSWindow(contentRect: opening.frame, styleMask: [.titled], backing: .buffered, defer: false)
openingWindow.isReleasedWhenClosed = false
for _ in 0..<3 {
    openingWindow.contentView = opening
    opening.layoutSubtreeIfNeeded()
    let clip = opening.subviews.compactMap { $0 as? NSScrollView }.first!.contentView
    let visible = clip.documentView!.subviews.compactMap { $0 as? FooterMixerHostingView }
        .filter { !$0.isHidden && $0.frame.intersects(clip.bounds) }
    precondition(!visible.isEmpty && visible.allSatisfy { $0.frame.height >= 724 && revealButtons($0).count == 1 },
                 "opening/reopening the mixer must reveal controls without scrolling or waiting for a timer")
    openingWindow.contentView = NSView()
    opening.update(width: 100 * 86 + 7, stride: 86, count: 100, makeContent: openingContent)
}
openingWindow.close()
print("FOOTER_OPEN_REOPEN_RETRIES_OFFWINDOW_CONTROLS_WITHOUT_WHEEL_OK")

let hiddenPanel = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 300))
let hiddenWindow = NSWindow(contentRect: hiddenPanel.frame, styleMask: [.titled], backing: .buffered, defer: false)
hiddenWindow.isReleasedWhenClosed = false
hiddenWindow.contentView = hiddenPanel
opening.frame = hiddenPanel.bounds; hiddenPanel.addSubview(opening)
opening.layoutSubtreeIfNeeded()
hiddenPanel.isHidden = true
opening.update(width: 100 * 86 + 7, stride: 86, count: 100, versions: Array(repeating: 2, count: 100), makeContent: openingContent)
precondition(!opening.pendingStripLayout.isEmpty, "Updates while the retained panel is closed must defer control preparation")
hiddenPanel.isHidden = false
opening.layoutSubtreeIfNeeded()
let reopenedClip = opening.subviews.compactMap { $0 as? NSScrollView }.first!.contentView
private let reopenedControls = reopenedClip.documentView!.subviews.compactMap { $0 as? FooterMixerHostingView }
    .filter { !$0.isHidden && $0.frame.intersects(reopenedClip.bounds) }
precondition(!reopenedControls.isEmpty && reopenedControls.allSatisfy { revealButtons($0).count == 1 },
             "Changes made while closed must show prepared controls immediately on reopen")
hiddenWindow.close()
print("FOOTER_RETAINED_HIDDEN_UPDATES_DEFER_PREPARATION_UNTIL_REOPEN_WITHOUT_BLANK_CONTROLS_OK")

// A reordered/replaced track has a new SwiftUI identity inside the same native
// channel. Nonzero control frames alone are insufficient: they must intersect
// the clipped viewport, rather than remain below it in the fixed 724pt host.
private let replacement = FooterMixerScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
let replacementWindow = NSWindow(contentRect: replacement.frame, styleMask: [.titled], backing: .buffered, defer: false)
replacementWindow.isReleasedWhenClosed = false
replacementWindow.contentView = replacement
replacementWindow.orderFront(nil)
let replacementScroll = replacement.subviews.compactMap { $0 as? NSScrollView }.first!
let replacementBar = replacement.subviews.compactMap { $0 as? NSScroller }.first!
var replacementRevision = 0
func replaceChannelIdentities() {
    replacementRevision += 1
    let identity = replacementRevision
    replacement.update(width: 100 * 86 + 7, stride: 86, count: 100,
                       versions: Array(repeating: UInt64(identity), count: 100)) { range in
        AnyView(HStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach(Array(range), id: \.self) { index in
                    FooterMixerStripGeometry(slotsOnly: false, iconHeight: 0, selected: false,
                        slots: AnyView(Color.gray), footer: { height in
                            AnyView(VStack { RevealControl().frame(height: 24); Spacer(minLength: 0) }
                                .frame(height: height + FooterMixerStripLayout.labelHeight))
                        }).frame(width: 83).frame(maxHeight: .infinity).id("\(identity)-\(index)")
                }
            }
        }.padding(5))
    }
}
func checkReplacementControls(_ stage: String) {
    let clip = replacementScroll.contentView
    let channels = clip.documentView!.subviews.compactMap { $0 as? FooterMixerHostingView }
        .filter { !$0.isHidden && $0.frame.intersects(clip.bounds) }
    precondition(!channels.isEmpty)
    for channel in channels {
        let controls = revealButtons(channel)
        let visible = controls.filter { !$0.isHiddenOrHasHiddenAncestor &&
            clip.bounds.intersects(clip.convert($0.bounds, from: $0)) }
        if controls.count != 1 || visible.count != 1 {
            fputs("REPLACEMENT_CONTROL \(stage) channel=\(channel.frame) clip=\(clip.bounds) controls=\(controls.map { clip.convert($0.bounds, from: $0) })\n", stderr)
        }
        precondition(controls.count == 1 && visible.count == 1,
                     "Replaced/revealed controls must be inside the visible channel: \(stage)")
    }
}
replaceChannelIdentities(); replacement.layoutSubtreeIfNeeded()
for pass in 0..<3 {
    for fraction in [0.0, 0.4, 0.0, 0.9, 0.2] {
        replacementBar.doubleValue = fraction
        replacementBar.sendAction(replacementBar.action, to: replacementBar.target)
        checkReplacementControls("scroll \(pass)/\(fraction)")
        replaceChannelIdentities()
        replacement.layoutSubtreeIfNeeded()
        checkReplacementControls("identity \(pass)/\(fraction)")
    }
    replacement.isHidden = true
    replaceChannelIdentities()
    replacement.isHidden = false
    replacement.layoutSubtreeIfNeeded()
    checkReplacementControls("reopen \(pass)")
}
replacementWindow.close()
print("FOOTER_REPLACED_TRACK_IDENTITIES_AND_REOPEN_KEEP_CONTROLS_INSIDE_VISIBLE_VIEWPORT_OK")

private let followWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 242), styleMask: [.borderless], backing: .buffered, defer: false)
private let follow = FooterMixerScrollView(frame: followWindow.contentView!.bounds)
followWindow.contentView = follow
var followIDs = (0..<900).map { _ in UUID() }
for _ in 0..<4 {
    let created = UUID(); followIDs.append(created)
    follow.update(width: CGFloat(followIDs.count) * 153, stride: 153, count: followIDs.count,
                  identifiers: followIDs, makeContent: { _ in AnyView(Color.black) })
    let request = UUID()
    follow.revealTrack(created, request: request)
    let clip = follow.subviews.compactMap { $0 as? NSScrollView }.first!
    let right = CGFloat(followIDs.count) * 153
    precondition(clip.contentView.bounds.maxX >= right - 1 && clip.contentView.bounds.minX <= right - 153,
                 "Each new copy stays completely visible in the horizontal mixer")
    let scrollbar = follow.subviews.compactMap { $0 as? NSScroller }.first!
    scrollbar.doubleValue = 0; scrollbar.sendAction(scrollbar.action, to: scrollbar.target)
    follow.revealTrack(created, request: request)
    precondition(clip.contentView.bounds.minX == 0, "An ordinary refresh cannot override later manual scrolling")
}
followWindow.close()
print("FOOTER_DUPLICATED_TRACK_FOLLOW_900_CHANNELS_OK")
