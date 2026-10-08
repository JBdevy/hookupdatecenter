private final class ShortcutHost: NSView, NativeTimelineBodyInputHost {
    weak var timelineBodyInput: (NSView & NativeTimelineBodyInput)?
    var fallbacks = 0
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let hit = timelineBodyHit(at: point) ?? timelineControlHit(at: point) { return hit }
        fallbacks += 1
        return super.hitTest(point)
    }
}

@MainActor private func verifyShortcut() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory); app.finishLaunching()
    let fixture = FixtureWindow(candidate: true, kinds: [.standard, .standard])
    fixture.change(96)
    fixture.window.orderFrontRegardless(); fixture.settle()
    defer { fixture.window.orderOut(nil); fixture.window.close() }
    let root = fixture.window.contentView as! ShortcutHost
    let scroll = root.subviews[0] as! GridNativeScrollView
    let rows = descendants(fixture.host, of: TrackMixerNativeControlView.self).sorted {
        $0.convert($0.bounds, to: fixture.host).minY < $1.convert($1.bounds, to: fixture.host).minY
    }
    let first = rows[0], second = rows[1]
    let firstControls = descendants(first.controls, of: TrackControlSelectionExclusionView.self)
    expect(firstControls.count == 2, "fixture must mount the real button and fader exclusion regions")
    func pointInParent(_ view: NSView, _ point: NSPoint) -> NSPoint { view.superview?.convert(point, from: nil) ?? point }
    func hit(_ point: NSPoint, enabled: Bool) -> NSView? {
        NativeTimelineControlInputRegistration.testEnabled = enabled
        return root.hitTest(pointInParent(root, point))
    }
    func buttonPoint(_ row: TrackMixerNativeControlView) -> NSPoint {
        let area = descendants(row.controls, of: TrackControlSelectionExclusionView.self).min {
            $0.convert($0.bounds, to: row.controls).minY < $1.convert($1.bounds, to: row.controls).minY
        }!
        return area.convert(NSPoint(x: 17, y: area.bounds.midY), to: nil)
    }
    func sameTarget(_ point: NSPoint, shortcut: Bool, _ message: String) {
        let ordinary = hit(point, enabled: false)
        let count = root.fallbacks
        let direct = hit(point, enabled: true)
        expect(ordinary != nil && direct === ordinary, "\(message): direct and ordinary native destinations differ")
        expect((root.fallbacks == count) == shortcut, "\(message): unexpected shortcut/fallback decision")
    }
    func verifyCursorRects(_ row: TrackMixerNativeControlView) {
        for area in descendants(row, of: TrackControlSelectionExclusionView.self) {
            area.discardCursorRects(); area.resetCursorRects()
            expect(area.recordedCursorRects.count == (area.bounds.intersection(area.visibleRect).isEmpty ? 0 : 1), "cursor rect covers only visible control pixels")
            if let (rect, cursor) = area.recordedCursorRects.first {
                expect(rect == area.bounds.intersection(area.visibleRect) && cursor === NSCursor.arrow, "control preserves the existing standard arrow")
            }
        }
    }
    verifyCursorRects(first); verifyCursorRects(second)
    let fx = buttonPoint(first)
    sameTarget(fx, shortcut: true, "SwiftUI FX button")
    sameTarget(buttonPoint(second), shortcut: true, "second row SwiftUI button")
    let volume = descendants(first, of: DirectVolumeSliderView.self).first { !$0.mini }!
    sameTarget(volume.convert(NSPoint(x: volume.bounds.midX, y: volume.bounds.midY), to: nil), shortcut: true, "native volume fader")
    let title = descendants(first, of: TrackDragTitleView.self).first!
    sameTarget(title.convert(NSPoint(x: title.bounds.midX, y: title.bounds.midY), to: nil), shortcut: false, "name/title native drag source")
    sameTarget(first.convert(NSPoint(x: 5, y: 80), to: nil), shortcut: false, "blank row background")
    sameTarget(first.convert(NSPoint(x: 240, y: 95), to: nil), shortcut: false, "row resize border")
    for buttons in [1, 2, 4] {
        expect(NativeTimelineControlInputRegistration.hit(at: root.convert(fx, from: nil), in: root,
            mouseButtons: buttons, modifiers: []) == nil, "pressed native buttons require ordinary click/drag/context routing")
    }
    expect(NativeTimelineControlInputRegistration.hit(at: root.convert(fx, from: nil), in: root,
        mouseButtons: 0, modifiers: .control) == nil, "Control click retains ordinary context routing")
    for target in [title.convert(NSPoint(x: title.bounds.midX, y: title.bounds.midY), to: nil), first.convert(NSPoint(x: 240, y: 95), to: nil)] {
        expect(!firstControls.contains { area in area.recordedCursorRects.contains { $0.0.contains(area.convert(target, from: nil)) } },
            "name and resize border remain outside every new arrow rectangle")
    }
    // Registering geometry must not itself replace a neighboring resize/knob
    // cursor. AppKit chooses the cursor only when its actual target is inside.
    NSCursor.resizeUpDown.set(); verifyCursorRects(first)
    expect(NSCursor.current === NSCursor.resizeUpDown, "registering a control arrow cannot set a cursor outside its region")
    NSCursor.arrow.set()
    print("MIXER_ARROW_CONTROL_BOUNDS_NAME_RESIZE_AND_NO_DIRECT_CURSOR_SET_OK")
    print("MIXER_INPUT_REAL_SWIFTUI_BUTTON_NATIVE_FADER_NAME_BLANK_BORDER_TARGETS_OK")

    // An NSHostingView button must receive real AppKit event dispatch. Its
    // action stays inside the existing SwiftUI host rather than a proxy view.
    var serial = 0
    func click(_ point: NSPoint, enabled: Bool) {
        NativeTimelineControlInputRegistration.testEnabled = enabled
        serial += 1
        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: timestamp,
            windowNumber: fixture.window.windowNumber, context: nil, eventNumber: serial * 2, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: timestamp + 0.01,
            windowNumber: fixture.window.windowNumber, context: nil, eventNumber: serial * 2 + 1, clickCount: 1, pressure: 0)!
        fixture.window.sendEvent(down); fixture.window.sendEvent(up); fixture.settle()
    }
    let baselineCalls = fixture.state.calls
    click(fx, enabled: false)
    expect(fixture.state.calls == baselineCalls + 1, "baseline real SwiftUI FX click must dispatch exactly once")
    click(fx, enabled: true)
    expect(fixture.state.calls == baselineCalls + 2, "shortcut real SwiftUI FX click must dispatch exactly once")
    fixture.state.enabled = false; fixture.settle()
    click(buttonPoint(first), enabled: true)
    expect(fixture.state.calls == baselineCalls + 2, "disabled SwiftUI button must not execute")
    fixture.state.enabled = true; fixture.settle()
    print("MIXER_INPUT_REAL_APPKIT_DISPATCH_AND_DISABLED_SWIFTUI_BUTTON_OK")

    NativeTimelineInputGate.shared.setBlocked(true, for: fixture.window)
    for area in descendants(fixture.host, of: TrackControlSelectionExclusionView.self) {
        expect(area.recordedCursorRects.isEmpty, "input gate immediately removes existing arrow cursor rectangles")
        area.resetCursorRects()
        expect(area.recordedCursorRects.isEmpty, "blocked controls do not register cursor rectangles")
    }
    sameTarget(buttonPoint(first), shortcut: false, "modal input gate")
    NativeTimelineInputGate.shared.setBlocked(false, for: fixture.window)
    verifyCursorRects(first)
    let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    sheet.isReleasedWhenClosed = false
    fixture.window.beginSheet(sheet)
    for area in firstControls {
        area.discardCursorRects(); area.resetCursorRects()
        expect(area.recordedCursorRects.isEmpty, "attached sheet owns cursor rectangles")
    }
    expect(root.timelineControlHit(at: pointInParent(root, buttonPoint(first))) == nil, "an attached sheet must disable direct routing")
    fixture.window.endSheet(sheet); sheet.orderOut(nil); sheet.close(); fixture.settle()
    sameTarget(buttonPoint(first), shortcut: true, "sheet close restores live control")
    verifyCursorRects(first)
    print("MIXER_INPUT_MODAL_GATE_SHEET_AND_REOPEN_OK")

    for height in [64.1, 24.0, 96.0] {
        fixture.change(height)
        verifyCursorRects(first)
        sameTarget(buttonPoint(first), shortcut: true, "continuous row height \(height)")
    }
    // Move only the row's native wrapper, without changing document size.
    let wrapper = first.superview!
    let oldOrigin = wrapper.frame.origin
    let oldPoint = buttonPoint(first)
    wrapper.setFrameOrigin(NSPoint(x: oldOrigin.x, y: oldOrigin.y + 240))
    expect(root.timelineControlHit(at: pointInParent(root, oldPoint)) == nil,
        "row-only reordering cannot retain the previous hit rectangle")
    expect(root.timelineControlHit(at: pointInParent(root, buttonPoint(first))) == nil,
        "a wrapper moved beyond its unchanged SwiftUI clipping slot must fall back")
    wrapper.setFrameOrigin(oldOrigin)
    fixture.settle()
    scroll.setFrameSize(NSSize(width: 248, height: 80)); scroll.tile()
    expect(root.timelineControlHit(at: pointInParent(root, buttonPoint(second))) == nil,
        "a warm retained row outside the viewport cannot receive pointer input")
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 96))
    verifyCursorRects(second)
    sameTarget(buttonPoint(second), shortcut: true, "vertical scroll immediately reaches existing row")
    scroll.setFrameSize(NSSize(width: 248, height: 795)); scroll.tile()
    scroll.contentView.scroll(to: .zero); fixture.settle()
    print("MIXER_INPUT_HEIGHT_REORDER_CLIP_AND_SCROLL_LIVE_GEOMETRY_OK")

    // Registration is weak and scoped to the host/window. A detached row never
    // produces a stale target even before another layout or cursor event occurs.
    let parent = first.superview!
    first.removeFromSuperview()
    expect(root.timelineControlHit(at: pointInParent(root, fx)) == nil, "detachment removes stale registered input")
    parent.addSubview(first); first.place(); fixture.settle()
    sameTarget(buttonPoint(first), shortcut: true, "reattached retained controls")
    NativeTimelineControlInputRegistration.testEnabled = true
    print("MIXER_INPUT_DETACH_REATTACH_AND_NO_CACHED_TARGET_OK")

    // A plain native wrapper reproduces reorder-only frame movement without
    // changing the document extent or leaving a stale SwiftUI clipping slot.
    let nativeWindow = NSWindow(contentRect: CGRect(x: -5000, y: -5000, width: 300, height: 320),
        styleMask: [.borderless], backing: .buffered, defer: false)
    nativeWindow.isReleasedWhenClosed = false
    let nativeRoot = ShortcutHost(frame: CGRect(x: 0, y: 0, width: 300, height: 320))
    let nativeScroll = GridNativeScrollView(frame: nativeRoot.bounds)
    let document = ShortcutHost(frame: CGRect(x: 0, y: 0, width: 300, height: 2400))
    nativeScroll.documentView = document; nativeRoot.addSubview(nativeScroll); nativeWindow.contentView = nativeRoot
    let wrapperA = ShortcutHost(frame: CGRect(x: 0, y: 50, width: 248, height: 96))
    let wrapperB = ShortcutHost(frame: CGRect(x: 0, y: 200, width: 248, height: 96))
    document.addSubview(wrapperA); document.addSubview(wrapperB)
    func addNativeRow(to parent: NSView) -> TrackMixerNativeControlView {
        let row = TrackMixerNativeControlView(frame: parent.bounds)
        row.controls.rootView = AnyView(Button("Probe") {}.frame(width: 60, height: 24)
            .background(TrackControlSelectionExclusion()).frame(width: 248, height: 64, alignment: .topLeading))
        parent.addSubview(row); row.place(); return row
    }
    let nativeA = addNativeRow(to: wrapperA), nativeB = addNativeRow(to: wrapperB)
    nativeWindow.orderFrontRegardless(); document.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.02)); document.layoutSubtreeIfNeeded()
    func probe(_ row: TrackMixerNativeControlView) -> NSPoint {
        let area = descendants(row, of: TrackControlSelectionExclusionView.self).first!
        return area.convert(NSPoint(x: area.bounds.midX, y: area.bounds.midY), to: nil)
    }
    func directProbe(_ row: TrackMixerNativeControlView) -> NSView? {
        nativeRoot.timelineControlHit(at: pointInParent(nativeRoot, probe(row)))
    }
    verifyCursorRects(nativeA); verifyCursorRects(nativeB)
    expect(directProbe(nativeA) != nil && directProbe(nativeB) != nil, "native wrapper controls must register")
    let oldProbe = probe(nativeA), documentSize = document.frame.size
    wrapperA.setFrameOrigin(NSPoint(x: 0, y: 110))
    verifyCursorRects(nativeA)
    expect(nativeRoot.timelineControlHit(at: pointInParent(nativeRoot, oldProbe)) == nil && directProbe(nativeA) != nil &&
        document.frame.size == documentSize, "ancestor-only reorder updates control locations without document resizing")
    // Front row begins ten points before A's button, so its blank lower area
    // overlaps A's control while its own control occupies another location.
    wrapperB.setFrameOrigin(NSPoint(x: 0, y: 65))
    expect(directProbe(nativeA) == nil, "front row blank space occluding rear control must preserve native z-order")
    wrapperB.setFrameOrigin(NSPoint(x: 0, y: 200))
    expect(directProbe(nativeA) != nil, "separating rows immediately restores shortcut")
    weak var released: TrackMixerNativeControlView?
    autoreleasepool {
        let transient = TrackMixerNativeControlView(frame: CGRect(x: 0, y: 350, width: 248, height: 96))
        document.addSubview(transient); transient.place(); released = transient
        transient.removeFromSuperview()
    }
    expect(released == nil, "input registrations must not retain removed rows")
    nativeWindow.orderOut(nil); nativeWindow.close()
    print("MIXER_INPUT_ANCESTOR_ONLY_REORDER_OVERLAP_OCCLUSION_AND_WEAK_LIFETIME_OK")
}


MainActor.assumeIsolated { verifyShortcut() }
