// Optional interactive regression: Quartz -> AppKit's real event queue -> the
// production NSViewRepresentable, inside a scaled SwiftUI hosting hierarchy.
// Uses an isolated defaults suite and restores the previously focused app.
private struct PostedMixerFixture: View {
    var body: some View {
        FooterMixerScroll(contentWidth: 2000, stride: 90, count: 20, active: true,
            masterWidth: 100, masterRight: false, masterVersion: 1,
            masterContent: AnyView(Text("Master")),
            versions: Array(repeating: 1, count: 20)) { range in
                AnyView(Text("Track \(range.lowerBound)").frame(maxHeight: .infinity).background(Color.gray))
            }
    }
}
private func postedMixer(in view: NSView) -> FooterMixerScrollView? {
    (view as? FooterMixerScrollView) ?? view.subviews.compactMap { postedMixer(in: $0) }.first
}
let app = NSApplication.shared
setbuf(stdout, nil)
app.setActivationPolicy(.regular)
let previousApp = NSWorkspace.shared.frontmostApplication
let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 242),
                      styleMask: [.titled], backing: .buffered, defer: false)
window.title = "CatLive mixer wheel validation"
window.contentView = NSHostingView(rootView: PostedMixerFixture().padding(12).scaleEffect(0.9))
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
    window.contentView?.layoutSubtreeIfNeeded()
    guard let view = postedMixer(in: window.contentView!) else { fatalError("Native mixer was not hosted") }
    guard let scroll = view.subviews.compactMap({ $0 as? NSScrollView }).first else { fatalError("Mixer scroll view not found") }
    let start = scroll.contentView.bounds.minX
    let screenPoint = window.convertPoint(toScreen: view.convert(NSPoint(x: 180, y: 100), to: nil))
    let point = CGPoint(x: screenPoint.x, y: NSScreen.screens[0].frame.height - screenPoint.y)
    let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                        wheel1: 0, wheel2: -3, wheel3: 0)!
    event.flags = .maskShift; event.location = point; event.post(tap: .cghidEventTap)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        let passed = scroll.contentView.bounds.minX > start
        print("MIXER_POSTED_SHIFT_WHEEL_SCROLLS", passed ? "OK" : "FAILED")
        window.orderOut(nil); previousApp?.activate(options: [])
        exit(passed ? 0 : 1)
    }
}
app.run()
