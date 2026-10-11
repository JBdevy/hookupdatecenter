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
precondition(document.subviews.count < 20, "channel host count remains bounded")
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
    precondition(channels.count <= Int(ceil(viewport.width / 153)) + 6,
                 "a narrowed mixer must release hosts outside its bounded scroll reserve")
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
precondition(scroll.documentView!.subviews.count <= 16,
             "focus and pinning retain only their own channels, not every intervening channel")
window.makeFirstResponder(nil); protectedChannels.removeAll()
// Same viewport uses prepare's containment fast path, which must also release
// previously protected channels once the gesture or menu has ended.
bar.sendAction(bar.action, to: bar.target)
precondition(focusedStrip.superview == nil && protectedStrip.superview == nil,
             "the next preparation releases finished focus/menu exceptions even without scrolling")
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
    precondition(channels.count >= 4 && channels.allSatisfy { $0.frame.width == 93 && $0.frame.height == scroll.contentSize.height },
        "Resizing the window changes the viewport while each retained channel keeps its supplied rectangle")
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
