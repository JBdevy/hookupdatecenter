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
    window.orderOut(nil)
    print("MACOS12_STABLE_NATIVE_CONTROLS_AND_LAYOUT_GEOMETRY_OK forceLegacy=\(JarasDrawingCompatibility.forceLegacy)")
}
