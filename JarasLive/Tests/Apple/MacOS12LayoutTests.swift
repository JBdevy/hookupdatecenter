private final class PlacementProbe: NSView {
    static var views: [Int: PlacementProbe] = [:]
    let identifierNumber: Int
    init(_ id: Int) { identifierNumber = id; super.init(frame: .zero); Self.views[id] = self }
    required init?(coder: NSCoder) { fatalError() }
}
private struct PlacedProbe: NSViewRepresentable {
    let id: Int
    func makeNSView(context: Context) -> PlacementProbe { PlacementProbe(id) }
    func updateNSView(_ view: PlacementProbe, context: Context) {}
}
private final class LayoutState: ObservableObject { @Published var height: CGFloat = 64 }
private struct PlacementFixture: View {
    @ObservedObject var state: LayoutState
    var body: some View {
        TrackMixerContinuousContainer(meterWidth: 12, standard: true, lowerTitle: true) {
            ForEach(0..<7) { index in PlacedProbe(id: index).frame(idealWidth: index == 3 ? 142 : nil).jarasPlaced(at: index) }
        }.frame(width: 260, height: state.height)
    }
}
private final class ButtonsState: ObservableObject {
    @Published var height: CGFloat = 64
    @Published var showsFader = true
}
private struct ButtonsFixture: View {
    @ObservedObject var state: ButtonsState
    let standard: Bool
    private var widths: [CGFloat] { standard ? [22, 22, 42, 22, 22] : [47, 22, 22] }
    var body: some View {
        TrackMixerContinuousContainer(meterWidth: 12, standard: standard, lowerTitle: true) {
            Color.clear.jarasPlaced(at: 0)
            Color.clear.jarasPlaced(at: 1)
            Color.clear.jarasPlaced(at: 2)
            TrackMixerButtonsContainer(standard: standard, showsFader: state.showsFader) {
                ForEach(widths.indices, id: \.self) { index in
                    PlacedProbe(id: 100 + index).frame(width: widths[index]).jarasPlaced(at: index)
                }
            }.clipped().modifier(LegacyControlsWidth()).jarasPlaced(at: 3)
            Color.clear.jarasPlaced(at: 4)
            Color.clear.jarasPlaced(at: 5)
            Color.clear.jarasPlaced(at: 6)
        }.frame(width: 260, height: state.height).clipped()
    }
}
MainActor.assumeIsolated {
    _ = NSApplication.shared
    let state = LayoutState()
    let host = NSHostingView(rootView: PlacementFixture(state: state))
    host.frame = CGRect(x: 0, y: 0, width: 260, height: 64)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
    for _ in 0..<3 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.025)) }
    let identities = PlacementProbe.views.mapValues(ObjectIdentifier.init)
    for height: CGFloat in [24, 63, 64, 240, 48, 64] {
        state.height = height; host.setFrameSize(CGSize(width: 260, height: height))
        for _ in 0..<3 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.025)) }
        precondition(PlacementProbe.views.mapValues(ObjectIdentifier.init) == identities, "height changes preserve all seven native controls")
        let expected = TrackMixerHeightGeometry.frames(width: 260, height: height, meterWidth: 12, standard: true, lowerTitle: true,
            controlsWidth: 142)
        for index in 0..<7 where expected[index].width > 0 && expected[index].height > 0 {
            let probe = PlacementProbe.views[index]!
            let actualRect = probe.convert(probe.bounds, to: host)
            let actual = actualRect.size
            precondition(abs(actual.width - expected[index].width) < 1 && abs(actual.height - expected[index].height) < 1,
                "legacy and modern layout use the same geometry, slot \(index) height \(height) actual \(actual) expected \(expected[index].size)")
            precondition(abs(actualRect.minX - expected[index].minX) < 1 && abs(actualRect.minY - expected[index].minY) < 1,
                "controls retain exact positions, slot \(index) height \(height) actual \(actualRect) expected \(expected[index])")
        }
    }
    // Exercise the complete nested five-control group. Widths are the explicit
    // production widths of FX, REC, pan, M and S; only visibility changes at 64.
    // Special tracks keep their independently sized HStack controls.
    for standard in [true, false] {
        let buttonState = ButtonsState()
        let buttonHost = NSHostingView(rootView: ButtonsFixture(state: buttonState, standard: standard))
        buttonHost.frame = CGRect(x: 0, y: 0, width: 260, height: 64)
        window.contentView = buttonHost
        func settleButtons() {
            for _ in 0..<3 {
                buttonHost.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.025))
            }
        }
        settleButtons()
        let widths: [CGFloat] = standard ? [22, 22, 42, 22, 22] : [47, 22, 22]
        let identities = widths.indices.map { ObjectIdentifier(PlacementProbe.views[100 + $0]!) }
        for showsFader in [true, false] {
            buttonState.showsFader = showsFader
            for height: CGFloat in [24, 63.9, 64, 240, 64.1, 48, 64] {
                buttonState.height = height
                buttonHost.setFrameSize(CGSize(width: 260, height: height))
                settleButtons()
                precondition(widths.indices.map { ObjectIdentifier(PlacementProbe.views[100 + $0]!) } == identities,
                    "compact/expanded mode and fader visibility preserve every native button")
                let expanded = height >= 64
                let visible = widths.indices.filter { !standard || !($0 == 2 && !expanded) && !($0 == 0 && expanded && !showsFader) }
                let groupWidth = visible.reduce(CGFloat(0)) { $0 + widths[$1] } + CGFloat(visible.count - 1) * 3
                let group = TrackMixerHeightGeometry.frames(width: 260, height: height, meterWidth: 12,
                    standard: standard, lowerTitle: true, controlsWidth: groupWidth)[3]
                var expectedX = group.minX
                for index in widths.indices {
                    let probe = PlacementProbe.views[100 + index]!
                    let actual = probe.convert(probe.bounds, to: buttonHost)
                    if visible.contains(index) {
                        precondition(abs(actual.width - widths[index]) < 0.1 && abs(actual.minX - expectedX) < 0.1,
                            "control width/position must match fixed production geometry: standard=\(standard), height=\(height), fader=\(showsFader), slot=\(index), actual=\(actual), expectedX=\(expectedX)")
                        // AppKit snaps fractional row heights to backing pixels.
                        precondition(abs(actual.height - group.height) < 1 && abs(actual.minY - group.minY) < 1,
                            "control height/position remains identical: standard=\(standard), height=\(height), slot=\(index), actual=\(actual), group=\(group)")
                        expectedX += widths[index] + 3
                    } else {
                        precondition(!actual.intersects(buttonHost.bounds), "hidden controls remain mounted outside the row")
                    }
                }
            }
        }
    }
    window.orderOut(nil)
    print("MACOS12_STABLE_NATIVE_CONTROLS_FIVE_BUTTON_METRICS_AND_LAYOUT_GEOMETRY_OK forceLegacy=\(JarasDrawingCompatibility.forceLegacy)")
}
