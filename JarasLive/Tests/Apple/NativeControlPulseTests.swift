private func expect(_ condition: Bool, _ message: String = "Pulse test failed", line: UInt = #line) {
    if !condition {
        FileHandle.standardError.write(Data(("line \(line): \(message)\n").utf8)); exit(1)
    }
}
@MainActor enum PulseJournal {
    static var clicks = 0
    static var labelClicks = 0
    static var editorOpened = 0
}
@MainActor private final class PulseFixtureState: ObservableObject {
    @Published var flashing = true
}
@MainActor private final class PulseRootHost<Content: View>: NSHostingView<Content> {
    var layouts = 0
    override func layout() { layouts += 1; super.layout() }
}
@MainActor private func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) }
}
@MainActor private func buttons(_ object: Any, depth: Int = 0) -> [any NSAccessibilityProtocol] {
    guard depth < 16, let ax = object as? any NSAccessibilityProtocol else { return [] }
    let own = ax.accessibilityRole() == .button ? [ax] : []
    return own + (ax.accessibilityChildren() ?? []).flatMap { buttons($0, depth: depth + 1) }
}
private struct PulseFixture: View {
    let show: ShowController
    @ObservedObject var state: PulseFixtureState
    var body: some View {
        HStack(spacing: 20) {
            Button { PulseJournal.clicks += 1 } label: {
                Text("STOP").frame(width: 70, height: 35).background(Color.green)
            }.buttonStyle(.plain).modifier(JarasBlink(active: state.flashing, interval: 0.08, lowOpacity: 0.2))
                .accessibilityLabel("Pulse action").jarasHelp("Pulse action help")
                .keyboardShortcut("b", modifiers: [])
            MetronomeControl(show: show)
            Button { PulseJournal.labelClicks += 1 } label: {
                Text("REC").frame(width: 30, height: 35).background(Color.red)
                    .modifier(JarasBlink(active: state.flashing, interval: 0.08, lowOpacity: 0.2))
            }.buttonStyle(.plain).accessibilityLabel("Pulse label action")
        }.padding(10)
    }
}

private struct PulseSizingProbe: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> PulseSizingProbeView { PulseSizingProbeView() }
    func updateNSView(_ view: PulseSizingProbeView, context: Context) { view.name = name }
}
private final class PulseSizingProbeView: NSView {
    var name = ""
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
private struct PulseSetlistSizingFixture: View {
    @ObservedObject var state: PulseFixtureState
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Text("EVENTO").frame(height: 26)
                Spacer()
                Button {} label: {
                    Text("STOP").font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6).frame(height: 26)
                        .background(Color.green)
                }.buttonStyle(.plain).modifier(JarasBlink(active: state.flashing, interval: 0.08))
            }.padding(.bottom, 6).background(PulseSizingProbe(name: "header"))
            Text("FIRST ROW").frame(height: 32).background(PulseSizingProbe(name: "first-row"))
            Spacer(minLength: 0)
        }.frame(width: 320, height: 650, alignment: .topLeading)
    }
}

MainActor.assumeIsolated {
    setbuf(stdout, nil)
    let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
    let song = Song(id: UUID())
    let show = ShowController(song: song)
    let state = PulseFixtureState()
    let root = PulseRootHost(rootView: PulseFixture(show: show, state: state))
    let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 220, height: 60),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = root; window.orderFront(nil)
    defer { window.orderOut(nil); window.close() }
    func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    pump(0.2)
    // Reproduce a natural-height setlist header inside a tall, expanding column.
    // The previous fixed-frame-only fixture missed the representable's vertical greed.
    let sizingState = PulseFixtureState(); sizingState.flashing = false
    let sizingRoot = NSHostingView(rootView: PulseSetlistSizingFixture(state: sizingState))
    let sizingWindow = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 320, height: 650), styleMask: [.borderless], backing: .buffered, defer: false)
    sizingWindow.isReleasedWhenClosed = false; sizingWindow.contentView = sizingRoot; sizingWindow.orderFront(nil)
    pump(0.1)
    @MainActor func sizingFrame(_ name: String) -> CGRect {
        let probe = descendants(sizingRoot, PulseSizingProbeView.self).first { $0.name == name }!
        return probe.convert(probe.bounds, to: sizingRoot)
    }
    let baselineHeader = sizingFrame("header"), baselineFirstRow = sizingFrame("first-row")
    precondition(baselineHeader.height == 32)
    sizingState.flashing = true; pump(0.1)
    let naturalBlink = descendants(sizingRoot, NativeJarasBlinkHost.self).first!
    precondition(naturalBlink.frame.height == 26 && sizingFrame("header") == baselineHeader && sizingFrame("first-row") == baselineFirstRow,
        "natural-height STOP must not expand the setlist header; baseline=\(baselineHeader) current=\(sizingFrame("header")) row=\(sizingFrame("first-row")) blink=\(naturalBlink.frame)")
    sizingWindow.orderOut(nil); sizingWindow.close()
    print("NATIVE_BLINK_NATURAL_HEIGHT_SETLIST_HEADER_BASELINE_GEOMETRY_OK")
    let blink = descendants(root, NativeJarasBlinkHost.self).first!
    let metronome = descendants(root, NativeMetronomePulseHost.self).first!
    let rootLayouts = root.layouts, blinkLayouts = blink.layoutCount, metronomeLayouts = metronome.layoutCount
    let songRefreshes = metronome.songRefreshCount

    // Test the compositor's observed output, not just its configured animation.
    var observed: [Float] = []
    for _ in 0..<24 { pump(0.015); if let opacity = blink.layer?.presentation()?.opacity { observed.append(opacity) } }
    precondition(observed.contains { $0 > 0.99 } && observed.contains { abs($0 - 0.2) < 0.01 },
        "discrete flash must reach both its bright and dim opacity; observed \(observed), frame \(blink.frame)")
    precondition(observed.allSatisfy { $0 > 0.99 || abs($0 - 0.2) < 0.01 }, "flash must not fade between transitions")
    precondition(root.layouts == rootLayouts && blink.layoutCount == blinkLayouts,
        "native flashing must not relayout the root or hosted controls")

    for position in [0.0, 0.1, 0.19, 0.49, 0.51, 0.68, 0.9] {
        show.sample(position)
        let section = song.tempoSection(at: position)
        let beat = (position - section.start) * section.bpm / 60 * Double(section.unit) / 4
        let expected: Float = beat.truncatingRemainder(dividingBy: 1) < 0.35 ? 1 : 0.45
        precondition(metronome.layer?.opacity == expected, "beat duty cycle changed at \(position)")
        precondition(metronome.layer?.animationKeys()?.isEmpty != false, "beat pulse must not lag through implicit animations")
        pump(0.015)
    }
    precondition(root.layouts == rootLayouts && metronome.layoutCount == metronomeLayouts,
        "beat changes must not relayout the root or hosted controls")
    precondition(metronome.songRefreshCount == songRefreshes, "transport ticks must reuse the cached song")
    show.sample(0.3, playing: false); precondition(metronome.layer?.opacity == 1)
    show.sample(0.3); precondition(metronome.layer?.opacity == 0.45)
    metronome.bind(show, enabled: false); precondition(metronome.layer?.opacity == 1)
    metronome.bind(show, enabled: true); precondition(metronome.layer?.opacity == 0.45)

    var edited = song
    edited.markers = [TimelineMarker(id: UUID(), position: 1, tempoBPM: 60, tempoUnit: 8)]
    show.editSong(edited); show.sample(1.2)
    precondition(metronome.layer?.opacity == 0.45, "tempo marker and beat unit changes must refresh the cached song")
    show.sample(1.05); precondition(metronome.layer?.opacity == 1)
    edited.bpm = 60; edited.markers = nil
    show.sample(0.3); show.editSong(edited)
    precondition(metronome.layer?.opacity == 1, "editing BPM during playback must refresh immediately")
    let nextSong = Song(id: UUID(), bpm: 60)
    var transition = show.snapshot
    transition.project.songs = [nextSong]; transition.transport.songId = nextSong.id
    transition.transport.position = 0.3
    show.snapshot = transition
    precondition(metronome.layer?.opacity == 1,
        "song transitions must use the incoming snapshot before Published stores it")

    let replacement = CALayer(); blink.layer = replacement; pump(0.02)
    precondition(replacement.animation(forKey: "jarasBlink") != nil, "replacement backing layer must retain flashing")
    let metronomeReplacement = CALayer(); metronome.layer = metronomeReplacement
    show.sample(0.7); precondition(metronomeReplacement.opacity == 0.45)
    blink.isHidden = true; precondition(replacement.animation(forKey: "jarasBlink") == nil)
    blink.isHidden = false; precondition(replacement.animation(forKey: "jarasBlink") != nil)
    metronome.isHidden = true; precondition(metronomeReplacement.opacity == 1)
    metronome.isHidden = false; precondition(metronomeReplacement.opacity == 0.45)
    blink.setBlink(active: false, interval: 0.08, lowOpacity: 0.2)
    precondition(replacement.animation(forKey: "jarasBlink") == nil && replacement.opacity == 1)
    pump(0.2); precondition(replacement.opacity == 1, "inactive flash must stay steady")
    print("NATIVE_PULSES_DISCRETE_CADENCE_BEAT_MARKER_BPM_STOP_OFF_VISIBILITY_LAYER_REPLACEMENT_NO_LAYOUT_OK")

    // Check the real SwiftUI control trees remain interactive and accessible.
    let center = blink.convert(CGPoint(x: blink.bounds.midX, y: blink.bounds.midY), to: blink.superview)
    precondition(blink.hitTest(center) != nil, "pulse host must retain normal hit testing")
    let controls = buttons(root)
    let action = controls.first { $0.accessibilityLabel() == "Pulse action" }
    let click = controls.first { $0.accessibilityLabel() == "Metronome" }
    let labelAction = controls.first { $0.accessibilityLabel() == "Pulse label action" }
    func mousePress(_ view: NSView) {
        let location = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 1.01,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
        // Native button implementations can track synchronously until MouseUp.
        app.postEvent(up, atStart: true); window.sendEvent(down); window.sendEvent(up); pump(0.03)
    }
    if controls.isEmpty {
        let baseline = NSHostingView(rootView: Button("Baseline") {}.frame(width: 70, height: 35))
        let baselineWindow = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 100, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false)
        baselineWindow.isReleasedWhenClosed = false
        baselineWindow.contentView = baseline; baselineWindow.orderFront(nil); pump(0.05)
        precondition(buttons(baseline).isEmpty, "native pulse lost accessibility available in the baseline")
        baselineWindow.orderOut(nil); baselineWindow.close()
        print("AX_OFFSCREEN_UNAVAILABLE_IN_BASELINE_AND_NATIVE_PULSES; app smoke required")
        mousePress(blink)
    } else {
        precondition(action != nil && click != nil && labelAction != nil, "accessible buttons disappeared in native hosts")
        precondition(action!.accessibilityPerformPress()); pump(0.03)
    }
    precondition(PulseJournal.clicks == 1, "press must reach the live button action")
    let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
        windowNumber: window.windowNumber, context: nil, characters: "b", charactersIgnoringModifiers: "b",
        isARepeat: false, keyCode: 11)!
    precondition(window.performKeyEquivalent(with: key), "hosted button must retain its keyboard shortcut")
    pump(0.03); precondition(PulseJournal.clicks == 2, "keyboard shortcut must reach the live button action")
    if let labelAction { precondition(labelAction.accessibilityPerformPress()); pump(0.03) }
    else { mousePress(descendants(root, NativeJarasBlinkHost.self)[1]) }
    precondition(PulseJournal.labelClicks == 1, "blinking labels must preserve the outer button action")
    if let click {
        precondition(click.accessibilityValue() as? String == "On")
        precondition(click.accessibilityPerformPress()); pump(0.05)
    } else { mousePress(metronome) }
    precondition(!MetronomeSettings.shared.enabled && metronome.layer?.opacity == 1)
    let point = metronome.convert(CGPoint(x: metronome.bounds.midX, y: metronome.bounds.midY), to: nil)
    let rightClick = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 1,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    precondition(RightClickRouter.shared.handle(rightClick), "metronome right click must remain routed")
    pump(0.1); precondition(PulseJournal.editorOpened == 1, "right click must open metronome settings")
    window.attachedSheet?.orderOut(nil)
    if let sheet = window.attachedSheet { window.endSheet(sheet) }
    print("NATIVE_PULSE_BUTTON_HIT_ACCESSIBILITY_ACTION_VALUE_KEYBOARD_AND_RIGHT_CLICK_SETTINGS_OK")

    precondition(window.makeFirstResponder(root), "control root must remain focusable")
    state.flashing = false; pump(0.1)
    precondition(descendants(root, NativeJarasBlinkHost.self).isEmpty,
        "inactive track controls must not add hosting trees to each display-cycle scan")
    precondition(window.firstResponder === root, "stopping flashing must preserve keyboard focus")
    precondition(window.performKeyEquivalent(with: key)); pump(0.03)
    precondition(PulseJournal.clicks == 3, "stopping flashing must preserve the keyboard action")
    state.flashing = true; pump(0.1)
    precondition(descendants(root, NativeJarasBlinkHost.self).count == 2)
    precondition(window.firstResponder === root, "restarting flashing must preserve keyboard focus")
    precondition(window.performKeyEquivalent(with: key)); pump(0.03)
    precondition(PulseJournal.clicks == 4, "restarting flashing must preserve the keyboard action")
    print("NATIVE_BLINK_ACTIVE_TRANSITION_RETAINS_CONTROLS_AND_IDLE_HAS_NO_EXTRA_HOSTS_OK")

    // Detaching must cancel observation, and neither native host retains show.
    metronome.removeFromSuperview(); show.sample(0.7)
    precondition(metronome.layer?.opacity == 1)
    weak var releasedShow: ShowController?
    weak var releasedHost: NativeMetronomePulseHost?
    autoreleasepool {
        let detached = NativeMetronomePulseHost(rootView: AnyView(Text("Pulse")))
        let temporaryShow = ShowController(song: song)
        releasedShow = temporaryShow; releasedHost = detached
        detached.bind(temporaryShow, enabled: true)
    }
    pump(0.05)
    precondition(releasedShow == nil && releasedHost == nil,
        "native pulse must not retain controller or itself; showReleased=\(releasedShow == nil), hostReleased=\(releasedHost == nil)")
    print("NATIVE_METRONOME_DETACH_CANCEL_AND_WEAK_LIFECYCLE_OK")
}
