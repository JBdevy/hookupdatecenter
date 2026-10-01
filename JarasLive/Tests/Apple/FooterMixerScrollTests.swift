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
