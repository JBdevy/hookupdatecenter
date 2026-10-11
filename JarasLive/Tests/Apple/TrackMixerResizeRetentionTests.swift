/// A real offscreen NSWindow resizes while the mixer stays at its saved width.
/// Warm every row first so hiding alone retains the same expensive view graph
/// as a show that has already scrolled through all its tracks.
@MainActor private func verifyResizeRetention() {
    let fixture = FixtureWindow(candidate: true, kinds: Array(repeating: .standard, count: 47))
    let scroll = fixture.window.contentView as! NSScrollView
    scroll.setFrameSize(CGSize(width: 248, height: 4096))
    fixture.settle()
    scroll.setFrameSize(CGSize(width: 248, height: 795))
    fixture.settle()
    let root = NSView(frame: CGRect(x: 0, y: 0, width: 1408, height: 795))
    fixture.window.contentView = root
    scroll.frame = CGRect(x: 0, y: 0, width: 248, height: 795)
    scroll.autoresizingMask = [.height]
    root.addSubview(scroll)
    let grid = NSView(frame: CGRect(x: 248, y: 0, width: 1160, height: 795))
    grid.wantsLayer = true; grid.autoresizingMask = [.width, .height]
    root.addSubview(grid)
    fixture.window.setContentSize(CGSize(width: 1408, height: 795))
    fixture.window.orderFront(nil)
    fixture.settle()
    func count(_ view: NSView) -> Int { 1 + view.subviews.reduce(0) { $0 + count($1) } }
    let rows = descendants(fixture.host, of: TrackMixerNativeControlView.self)
    expect(rows.count == 47, "All warm row owners remain mounted")
    let hostCount = descendants(root, of: TrackMixerControlHost.self).count
    let treeCount = count(root)
    let detached = rows.filter { $0.controls.superview == nil }.count
    for i in 0..<4 {
        fixture.window.setContentSize(CGSize(width: 1410 + i * 12, height: 795))
        fixture.settle()
    }
    Counts.reset()
    let start = clock(), started = ProcessInfo.processInfo.systemUptime
    for i in 0..<120 {
        let width = 1408 + CGFloat(i % 40) * 12
        fixture.window.setContentSize(CGSize(width: width, height: 795))
        fixture.settle()
    }
    let cpuMS = Double(clock() - start) * 1000 / Double(CLOCKS_PER_SEC)
    let elapsedMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
    let result: [String: Any] = ["detached": detached, "hosts": hostCount,
        "views": treeCount, "steps": 120, "cpuMS": cpuMS, "elapsedMS": elapsedMS,
        "slotLayouts": Counts.slotLayouts, "rootUpdates": Counts.update]
    print("MIXER_WINDOW_RESIZE " + String(data: try! JSONSerialization.data(withJSONObject: result, options: .sortedKeys), encoding: .utf8)!)
    fixture.window.close()
}


private final class RetentionInputHost: NSView, NativeTimelineBodyInputHost {
    weak var timelineBodyInput: (NSView & NativeTimelineBodyInput)?
}

@MainActor private func verifyDetachedRetention() {
    let fixture = FixtureWindow(candidate: true, kinds: Array(repeating: .standard, count: 47))
    let scroll = fixture.window.contentView as! NSScrollView
    let inputHost = RetentionInputHost(frame: CGRect(x: 0, y: 0, width: 248, height: 795))
    fixture.window.contentView = inputHost
    inputHost.addSubview(scroll)
    fixture.window.orderFront(nil)
    scroll.setFrameSize(CGSize(width: 248, height: 4096)); fixture.settle()
    let owners = descendants(fixture.host, of: TrackMixerNativeControlView.self)
    let row = owners[30]
    let hosts = [row.meter, row.activity, row.controls]
    let identities = hosts.map(ObjectIdentifier.init)
    let sliders = descendants(row.controls, of: DirectVolumeSliderView.self)
    let sliderIDs = sliders.map(ObjectIdentifier.init)
    let title = descendants(row.controls, of: TrackDragTitleView.self).first!
    let probe = descendants(row.controls, of: StatefulProbeView.self).first!
    probe.action?(); fixture.settle()
    expect(probe.value == 1, "Fixture must have live SwiftUI local state before detaching")
    let nativeMeter = descendants(row.meter, of: NativeVerticalTrackMeterView.self).first!
    let controlArea = descendants(row.controls, of: TrackControlSelectionExclusionView.self).first!
    expect(controlArea.window === fixture.window, "Control-area registration starts in the live window")
    scroll.setFrameSize(CGSize(width: 248, height: 795)); fixture.settle()
    let accessibility = NSApp.isFullKeyboardAccessEnabled || NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled
    expect(row.isHidden != accessibility, "Only inactive offscreen controls are detached")
    expect(hosts.allSatisfy { accessibility ? $0.window === fixture.window : $0.window == nil }, "Hidden hosts must actually leave the window hierarchy")
    expect(accessibility || controlArea.window == nil, "Detached button areas must leave the window input hierarchy")
    expect(row.window === fixture.window && descendants(fixture.host, of: TrackMixerNativeControlView.self).count == 47,
        "Row owners and viewport observation remain mounted")
    let oldSnapshot = row.snapshot
    fixture.state.title = "Updated while detached Árvore 木琴"
    fixture.state.value = -7
    fixture.state.actionStep = 9
    fixture.state.locale = "pt_BR"
    fixture.state.dark = false
    fixture.state.enabled = false
    fixture.state.project = UUID(); fixture.state.track = UUID()
    fixture.state.meter.update(peak: 1.25, elapsed: 0.05)
    fixture.settle()
    expect(row.snapshot !== oldSnapshot, "The model still replaces the snapshot for an offscreen retained host")
    let frame = row.convert(row.bounds, to: scroll.contentView)
    scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, frame.minY - 150)))
    fixture.settle()
    expect(hosts.map(ObjectIdentifier.init) == identities && hosts.allSatisfy { $0.superview === row && $0.window === fixture.window }, "Reattach must preserve all three existing hosting roots")
    expect(descendants(row.controls, of: DirectVolumeSliderView.self).map(ObjectIdentifier.init) == sliderIDs,
        "Detach/rebind/reattach must retain native fader instances")
    expect(descendants(row.controls, of: StatefulProbeView.self).first === probe && probe.value == 1,
        "SwiftUI local state survives detachment and snapshot updates")
    expect(title.title == fixture.state.title && title.project == fixture.state.project && title.track == fixture.state.track,
        "Reattached title must show the latest project, track and model")
    expect(sliders.allSatisfy { $0.boundProject == fixture.state.project && $0.boundTrack == fixture.state.track },
        "Reattached faders must not target the former project")
    expect(sliders.first(where: { !$0.mini })?.doubleValue == -7 && probe.locale == "pt_BR" && !probe.enabled && !probe.dark,
        "Detached content receives volume, locale, disabled and appearance updates")
    let before = fixture.state.calls
    title.select?()
    expect(fixture.state.calls == before + 9, "Reattached controls invoke the latest callback")
    fixture.state.enabled = true; fixture.settle()
    expect(controlArea.window === fixture.window, "The same button area resumes window registration on reattach")
    let buttonPoint = controlArea.convert(NSPoint(x: controlArea.bounds.midX, y: controlArea.bounds.midY), to: nil)
    let localButtonPoint = inputHost.convert(buttonPoint, from: nil)
    expect(row.hitTestTimelineControl(atWindowPoint: buttonPoint) != nil,
        "Reattached button area must register with its retained row owner")
    expect(NativeTimelineControlInputRegistration.hit(at: localButtonPoint, in: inputHost, mouseButtons: 0, modifiers: []) != nil,
        "The complete timeline input shortcut must reach reattached buttons")
    NativeTimelineInputGate.shared.setBlocked(true, for: fixture.window)
    expect(NativeTimelineControlInputRegistration.hit(at: localButtonPoint, in: inputHost, mouseButtons: 0, modifiers: []) == nil,
        "Reattached controls must still honor modal input blocking")
    NativeTimelineInputGate.shared.setBlocked(false, for: fixture.window)
    let accessibleButtons = axButtons(row.controls)
    if let fx = accessibleButtons.first(where: { $0.accessibilityLabel() == "FX" }) {
        let beforeAX = fixture.state.calls
        expect(fx.accessibilityPerformPress(), "The reattached FX accessibility button is actionable")
        fixture.settle()
        expect(fixture.state.calls > beforeAX, "The reattached accessibility action reaches the model")
    } else {
        expect(axButtons(owners.first!.controls).isEmpty, "Reattached row cannot lose accessibility when untouched controls have it")
        print("RETENTION_AX_OFFSCREEN_UNAVAILABLE_REQUIRES_APP_SMOKE")
    }
    nativeMeter.refreshVisibleDrawing()
    let peak = nativeMeter.layer!.sublayers!.first { $0.name == "meter-peak" }!
    expect(!peak.isHidden && peak.frame.width > 0, "Retained meters resume showing peaks received while offscreen")
    let peakPoint = nativeMeter.convert(NSPoint(x: peak.frame.midX, y: peak.frame.midY), to: nil)
    expect(row.hitTestTimelineControl(atWindowPoint: peakPoint) === nativeMeter, "Peak input routing resumes after reattaching")
    let down = NSEvent.mouseEvent(with: .leftMouseDown, location: peakPoint, modifierFlags: [], timestamp: 1,
        windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    nativeMeter.mouseDown(with: down)
    expect(fixture.state.meter.peakHold.decibels == nil, "Reattached peak reset changes the live model")
    let slider = sliders.first!
    expect(fixture.window.makeFirstResponder(slider), "Native fader accepts keyboard focus")
    scroll.contentView.scroll(to: .zero); fixture.settle()
    expect(hosts.allSatisfy { $0.window === fixture.window } && fixture.window.firstResponder === slider,
        "Focused descendant hosts cannot detach when scrolling away")
    fixture.window.makeFirstResponder(nil)
    TrackSelectionRouter.shared.pinnedTracks.insert(fixture.state.track)
    row.refreshViewportVisibility()
    expect(hosts.allSatisfy { $0.window === fixture.window }, "An active drag or menu pins the retained hosts")
    TrackSelectionRouter.shared.pinnedTracks.removeAll()
    row.refreshViewportVisibility()
    expect(hosts.allSatisfy { accessibility ? $0.window === fixture.window : $0.window == nil },
        "Ending focus/drag permits detachment on the next viewport refresh")
    fixture.window.close()
    print("TRACK_MIXER_DETACHED_STATE_MODEL_ACTION_ENVIRONMENT_METERS_HIT_TEST_FOCUS_AND_PIN_RETENTION_OK")
}
