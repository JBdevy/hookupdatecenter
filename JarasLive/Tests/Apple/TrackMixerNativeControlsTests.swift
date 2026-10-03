@MainActor private func axButtons(_ object: Any, depth: Int = 0) -> [any NSAccessibilityProtocol] {
    guard depth < 15, let ax = object as? any NSAccessibilityProtocol else { return [] }
    let own = ax.accessibilityRole() == .button ? [ax] : []
    return own + (ax.accessibilityChildren() ?? []).flatMap { axButtons($0, depth: depth + 1) }
}
@MainActor private func verifyBehavior() {
    let fixture = FixtureWindow(candidate: true, kinds: [.standard])
    fixture.change(80)
    let title = descendants(fixture.host, of: TrackDragTitleView.self).first!
    let faders = descendants(fixture.host, of: DirectVolumeSliderView.self)
    let original = faders.map(ObjectIdentifier.init)
    let originalTitle = ObjectIdentifier(title)
    let stateful = descendants(fixture.host, of: StatefulProbeView.self).first!
    let localStateIdentity = ObjectIdentifier(stateful)
    stateful.action?(); fixture.settle()
    expect(stateful.value == 1, "Initial stateful action failed")
    let sliders = faders.sorted { $0.mini && !$1.mini }
    let pan = sliders[0]
    let location = pan.convert(NSPoint(x: pan.bounds.maxX - 3, y: pan.bounds.midY), to: nil)
    let before = fixture.state.calls
    let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 1, windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 1.01, windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
    pan.mouseDown(with: down)
    expect(pan.trackingPointer && fixture.window.firstResponder === pan, "Native fader must retain pointer/focus state")
    for height in [96.0,63.9,24,64.1,80] { fixture.change(height) }
    expect(descendants(fixture.host, of: DirectVolumeSliderView.self).map(ObjectIdentifier.init) == original, "Height changes recreated faders")
    expect(ObjectIdentifier(descendants(fixture.host, of: TrackDragTitleView.self).first!) == originalTitle, "Height changes recreated title/drag source")
    expect(pan.trackingPointer && fixture.window.firstResponder === pan, "Resizing lost an active pointer gesture/focus")
    pan.mouseUp(with: up)
    expect(!pan.trackingPointer && fixture.state.calls > before, "Fader action did not complete")
    let retained = descendants(fixture.host, of: StatefulProbeView.self).first!
    expect(ObjectIdentifier(retained) == localStateIdentity && retained.value == 1, "Local SwiftUI state did not survive resize")
    fixture.state.title = "Updated long name Árvore 木琴"
    fixture.state.value = -4
    fixture.state.project = UUID(); fixture.state.track = UUID()
    fixture.settle()
    expect(title.title == fixture.state.title && title.track == fixture.state.track && title.project == fixture.state.project, "Recycled title kept old identity/content")
    for fader in faders { expect(fader.boundTrack == fixture.state.track && fader.boundProject == fixture.state.project, "Recycled fader kept old identity") }
    expect(faders.first(where: { !$0.mini })?.doubleValue == -4, "New volume was not delivered")
    let env = descendants(fixture.host, of: StatefulProbeView.self).first!
    expect(env.locale == "en" && env.enabled, "Initial environment missing")
    fixture.state.locale = "pt_BR"; fixture.state.enabled = false; fixture.settle()
    expect(env.locale == "pt_BR" && !env.enabled, "Nested hosting lost locale/isEnabled propagation")
    fixture.state.enabled = true; fixture.settle()
    let controls = descendants(fixture.host, of: TrackMixerNativeControlView.self).first!.controls
    let fxPoint = controls.convert(NSPoint(x: 113, y: 13), to: controls.superview)
    expect(controls.hitTest(fxPoint) != nil, "FX hit area disappeared")
    let baseline = FixtureWindow(candidate: false, kinds: [.standard]); baseline.change(80)
    let oldButtons = axButtons(baseline.host), buttons = axButtons(fixture.host)
    if oldButtons.isEmpty && buttons.isEmpty {
        print("AX_OFFSCREEN_UNAVAILABLE_IN_BASELINE_AND_CANDIDATE; app smoke required")
    } else {
        expect(buttons.count >= oldButtons.count, "Accessible controls were lost")
        let fx = buttons.first { $0.accessibilityLabel() == "FX" }
        expect(fx != nil, "FX accessibility button not found")
        let count = fixture.state.calls
        expect(fx!.accessibilityPerformPress(), "FX accessibility press rejected")
        fixture.settle()
        expect(fixture.state.calls > count, "FX press did not reach current callback")
    }
    baseline.window.close()
    print("NATIVE_ROW_BEHAVIOR_OK actions rebind state focus locale disabled hit-area")
    fixture.window.close()
}
private final class StatefulProbeView: NSView {
    var value = 0; var locale = ""; var enabled = false; var action: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
private struct StatefulProbe: NSViewRepresentable {
    @Binding var value: Int
    @Environment(\.locale) var locale
    @Environment(\.isEnabled) var enabled
    func makeNSView(context: Context) -> StatefulProbeView { StatefulProbeView() }
    func updateNSView(_ view: StatefulProbeView, context: Context) {
        view.value=value;view.locale=locale.identifier;view.enabled=enabled;view.action={value += 1}
    }
}
private struct StatefulControl: View {
    @State private var value=0
    var body: some View { StatefulProbe(value: $value).frame(width:1,height:1).allowsHitTesting(false) }
}

private func expect(_ ok: Bool, _ message: @autoclosure () -> String) { if !ok { FileHandle.standardError.write(Data((message()+"\n").utf8)); exit(1) } }
private enum Kind: String, CaseIterable { case standard, click, timecode, video, teleprompter }
@MainActor private final class FixtureState: ObservableObject {
    @Published var height: CGFloat = 64
    @Published var width: CGFloat = 248
    @Published var title = "08 · Árvore 木琴 / Stereo synth long track name"
    @Published var enabled = true
    @Published var value = -10.0
    var calls = 0
    @Published var project = UUID()
    @Published var track = UUID()
    @Published var locale = "en"
    let meter = TrackMeterLevel()
    let drag = TrackReorderState()
}
private struct TestDrop: DropDelegate { let height: CGFloat; func performDrop(info: DropInfo) -> Bool { false } }
private struct FixtureRow: View, Equatable {
    let candidate: Bool
    let kind: Kind
    let state: FixtureState
    let title: String
    let value: Double
    let project: UUID
    let track: UUID
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.candidate == rhs.candidate && lhs.kind == rhs.kind && lhs.state === rhs.state && lhs.title == rhs.title && lhs.value == rhs.value && lhs.project == rhs.project && lhs.track == rhs.track }
    private var lowerTitle: Bool { kind != .teleprompter }
    private var meter: some View { VerticalTrackMeter(meter: state.meter, showScale: true).clipped().allowsHitTesting(false) }
    private var midi: some View { Color.green.frame(width: 4).allowsHitTesting(false) }
    @ViewBuilder private func controls(split: Bool) -> some View {
        TrackMixerContinuousContainer(meterWidth: 40, standard: kind == .standard, lowerTitle: lowerTitle) {
            Group { if split { Color.clear } else { meter } }.jarasPlaced(at: 0)
            Group { if split { Color.clear } else { midi } }.jarasPlaced(at: 1)
            TrackDragTitle(title: title, foreground: 0xffffff, project: project, track: track, state: state.drag, select: { state.calls += 1 }).jarasPlaced(at: 2)
            TrackMixerButtonsContainer(standard: kind == .standard, showsFader: true) {
                if kind == .standard {
                    Button("FX") { state.calls += 1 }.frame(width: 22).jarasPlaced(at: 0)
                    Button("REC") { state.calls += 1 }.contextMenu { Button("Mono") {} ; Button("Stereo") {} ; Button("MIDI") {} }.jarasPlaced(at: 1)
                    DirectVolumeSlider(identity: .init(project: project, track: track), value: 0, minimum: -1, maximum: 1, mini: true, changed: { _ in state.calls += 1 }, editingChanged: { _,_ in }).frame(width: 42, height: 24).clipped().jarasPlaced(at: 2)
                } else if kind == .click {
                    Button("Insert") { state.calls += 1 }.buttonStyle(CompactTrackButtonStyle(width: 47)).fixedSize(horizontal: true, vertical: false)
                } else {
                    HStack(spacing: 3) {
                        if kind == .timecode { Button { state.calls += 1 } label: { Image(systemName: "gearshape") }; Button("MTC") {}; Button("LTC") {} }
                        else { Button(kind == .video ? "Add media" : "Add text") { state.calls += 1 } }
                    }.buttonStyle(TrackControlButtonStyle()).fixedSize()
                }
                Button("M") { state.calls += 1 }.frame(width: 22).jarasPlaced(at: 3)
                Button("S") { state.calls += 1 }.frame(width: 22).jarasPlaced(at: 4)
            }.buttonStyle(CompactTrackButtonStyle()).background { if CommandLine.arguments.contains("--behavior") { StatefulControl() } }.clipped().modifier(LegacyControlsWidth()).jarasPlaced(at: 3)
            Group { if lowerTitle { DirectVolumeSlider(identity: .init(project: project, track: track), value: value, changed: { _ in state.calls += 1 }, editingChanged: { _,_ in }) } else { Color.clear } }.clipped().jarasPlaced(at: 4)
            Image(systemName: "folder.fill").font(.system(size: 11)).foregroundStyle(Color.green).allowsHitTesting(false).jarasPlaced(at: 5)
            Group { if kind == .teleprompter { Button("Add media") { state.calls += 1 }.buttonStyle(TrackControlButtonStyle()) } else { Color.clear } }.clipped().jarasPlaced(at: 6)
        }
    }
    var body: some View {
        Group {
            if candidate { NativeTrackMixerControls(meterWidth: 40, standard: kind == .standard, meter: { meter }, activity: { midi }, controls: { controls(split: true) }) }
            else { controls(split: false) }
        }.frame(maxHeight: .infinity).clipped()
         .background { HStack(spacing: 0) { Color(red: 0.12, green: 0.2, blue: 0.16).opacity(0.5) }.allowsHitTesting(false) }
         .overlay { Rectangle().stroke(.white.opacity(0.65), lineWidth: 1).allowsHitTesting(false) }
         .overlay(alignment: .bottom) { Rectangle().fill(Color.gray).frame(height: 1).allowsHitTesting(false) }
         .background { GeometryReader { geometry in Color.clear.onDrop(of: [UTType.text], delegate: TestDrop(height: geometry.size.height)) } }
    }
}
private struct Fixture: View {
    @ObservedObject var state: FixtureState
    let candidate: Bool
    let kinds: [Kind]
    var body: some View {
        TimelineTrackRowsContainer(width: state.width, height: max(795, CGFloat(kinds.count) * state.height), top: 0, offsets: kinds.indices.map { CGFloat($0) * state.height }, rowHeights: kinds.map { _ in state.height }) {
            ForEach(kinds.indices, id: \.self) { index in
                FixtureRow(candidate: candidate, kind: kinds[index], state: state, title: state.title, value: state.value, project: state.project, track: state.track).equatable().frame(height: state.height).clipped().jarasPlaced(at: index)
            }
        }.frame(width: state.width, height: max(795, CGFloat(kinds.count) * state.height), alignment: .topLeading)
         .environment(\.locale, Locale(identifier: state.locale))
         .environment(\.colorScheme, .dark)
         .disabled(!state.enabled)
    }
}
@MainActor private final class FixtureWindow {
    let state = FixtureState()
    let count: Int
    let window: NSWindow
    let host: NSHostingView<Fixture>
    init(candidate: Bool, kinds: [Kind]) {
        count = kinds.count
        host = NSHostingView(rootView: Fixture(state: state, candidate: candidate, kinds: kinds))
        if #available(macOS 13, *) { host.sizingOptions = [] }
        if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
        window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 248, height: 795), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 248, height: 795))
        scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
        host.frame = NSRect(x: 0, y: 0, width: 248, height: CGFloat(kinds.count) * 64)
        scroll.documentView = host
        window.contentView = scroll
        settle()
    }
    func settle() {
        host.layoutSubtreeIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        host.layoutSubtreeIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
    }
    func change(_ height: CGFloat, width: CGFloat = 248) { state.height = height; state.width = width; host.setFrameSize(NSSize(width: width, height: max(795, CGFloat(count) * height))); settle() }
}
private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, of: type) } }
@MainActor private func frames(_ fixture: FixtureWindow) -> [String: [CGRect]] {
    ["title": descendants(fixture.host, of: TrackDragTitleView.self).map { $0.convert($0.bounds, to: fixture.host) },
     "slider": descendants(fixture.host, of: DirectVolumeSliderView.self).map { $0.convert($0.bounds, to: fixture.host) },
     "meter": descendants(fixture.host, of: NativeVerticalTrackMeterView.self).map { $0.convert($0.bounds, to: fixture.host) }]
}
@MainActor private func run() {
_ = NSApplication.shared
if CommandLine.arguments.contains("--behavior") { verifyBehavior() } else if CommandLine.arguments.contains("--geometry") {
    for kind in Kind.allCases {
        let baseline = FixtureWindow(candidate: false, kinds: [kind])
        let candidate = FixtureWindow(candidate: true, kinds: [kind])
        for width in [160.0,248,420] {
        for height in [24.0,36,40,48,55.9,56,63.9,64,64.1,80,120,240] {
            baseline.change(height, width: width); candidate.change(height, width: width)
            let a = frames(baseline), b = frames(candidate)
            for key in ["title", "slider", "meter"] {
                expect(a[key]!.count == b[key]!.count, "View identities mismatch \(kind) \(key)")
                for (old,new) in zip(a[key]!,b[key]!) {
                    // Hidden zero-sized controls stay outside the clipped row.
                    if old.minX > width || old.width <= 0 || old.height <= 0 { continue }
                    expect(abs(old.minX-new.minX)<1.1 && abs(old.minY-new.minY)<1.1 && abs(old.width-new.width)<1.1 && abs(old.height-new.height)<1.1, "Geometry \(kind) h\(height) \(key): \(old) vs \(new)")
                }
            }
        }
        }
        baseline.window.close();candidate.window.close()
    }
    print("NATIVE_ROW_CANONICAL_GEOMETRY_OK 5 kinds x12 heights x3 widths")
} else {
    let variant = CommandLine.arguments.contains("--candidate")
    let fixture = FixtureWindow(candidate: variant, kinds: Array(repeating: .standard, count: 47))
    for height in [64.0,72,64] { fixture.change(height) }
    Counts.reset()
    let started = ProcessInfo.processInfo.systemUptime
    let heights = Array(stride(from: 64.0, through: 112, by: 2)) + Array(stride(from: 110.0, through: 64, by: -2))
    for height in heights { fixture.change(height) }
    let elapsed = (ProcessInfo.processInfo.systemUptime-started)*1000
    let result: [String:Any] = ["candidate":variant,"steps":heights.count,"origin":Counts.origin,"size":Counts.size,"slotLayouts":Counts.slotLayouts,"rootUpdates":Counts.update,"nativeSliders":descendants(fixture.host,of:DirectVolumeSliderView.self).count,"elapsedMS":elapsed]
    print(String(data: try! JSONSerialization.data(withJSONObject: result,options:.sortedKeys),encoding:.utf8)!)
    fixture.window.close()
}

}
MainActor.assumeIsolated { run() }
