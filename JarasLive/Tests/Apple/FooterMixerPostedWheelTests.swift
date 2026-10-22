// Optional interactive regression: Quartz -> AppKit's real event queue -> the
// production NSViewRepresentable, inside a scaled SwiftUI hosting hierarchy.
// Uses an isolated defaults suite and restores the previously focused app.
private let postedSuite = "CatLive.MixerWheelFixture.\(UUID().uuidString)"
private let postedDefaults = UserDefaults(suiteName: postedSuite)!
private var postedModes: [Bool] = []
private var postedPresentationModes: [Bool] = []
private func setPostedMode(_ value: Bool) {
    postedModes.append(value)
    postedDefaults.set(value, forKey: "catlive.hozMixer.slotsOnly")
}
private struct PostedMixerFixture: View {
    @AppStorage("catlive.hozMixer.slotsOnly", store: postedDefaults) private var slotsOnly = false
    var body: some View {
        let _ = postedPresentationModes.append(slotsOnly)
        FooterMixerScroll(contentWidth: 2000, stride: 90, count: 20, active: true,
            masterWidth: 100, masterRight: false, masterVersion: slotsOnly ? 2 : 1,
            masterContent: AnyView(Text(slotsOnly ? "Master slots" : "Master normal")),
            versions: Array(repeating: slotsOnly ? 2 : 1, count: 20)) { range in
                AnyView(Text("Track \(range.lowerBound)").frame(maxHeight: .infinity)
                    .background(slotsOnly ? Color.green : Color.gray))
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
let source = CGEventSource(stateID: .hidSystemState)!
func postedShift(_ down: Bool) {
    let event = CGEvent(keyboardEventSource: source, virtualKey: 56, keyDown: down)!
    event.flags = down ? .maskShift : []; event.post(tap: .cghidEventTap)
}
func postedWheel(_ lines: Int32, point: CGPoint) {
    let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1,
                        wheel1: lines, wheel2: 0, wheel3: 0)!
    event.flags = .maskShift; event.location = point; event.post(tap: .cghidEventTap)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
    window.contentView?.layoutSubtreeIfNeeded()
    guard let view = postedMixer(in: window.contentView!) else { fatalError("Native mixer was not hosted") }
    let screenPoint = window.convertPoint(toScreen: view.convert(NSPoint(x: 50, y: 100), to: nil))
    let point = CGPoint(x: screenPoint.x, y: NSScreen.screens[0].frame.height - screenPoint.y)
    postedShift(true)
    for n in 0..<3 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1 + Double(n) * 0.08) { postedWheel(1, point: point) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { postedShift(false) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
        precondition(postedModes == [true] && postedPresentationModes.contains(true),
                     "Three real Shift wheel notches must update both persisted mode and SwiftUI presentation")
        postedShift(true)
        for n in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1 + Double(n) * 0.08) { postedWheel(-1, point: point) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { postedShift(false) }
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
    let passed = postedModes == [true, false] && postedPresentationModes.last == false
    print("MIXER_POSTED_QUARTZ_SHIFT_WHEEL_SCALED_SWIFTUI_PERSISTENCE", passed ? "OK" : "FAILED", postedModes)
    postedShift(false)
    postedDefaults.removePersistentDomain(forName: postedSuite)
    window.orderOut(nil); previousApp?.activate(options: [])
    exit(passed ? 0 : 1)
}
app.run()
