final class HeaderTestState: ObservableObject {
    @Published var offset: CGFloat = 0
    @Published var width: CGFloat = 760
    @Published var project = UUID()
    @Published var revision: UInt64 = 0
    @Published var editing: UUID?
    @Published var locale = Locale(identifier: "en")
    var name = "Original"
    var edits = 0
    var callbackValue = ""
}
private struct Song {}
private final class HeaderSnapShow {
    struct SubPlay { var playing = false; var position = 0.0 }
    struct Transport { var editPosition: Double? = 10; var position = 5.0; var subPlay = SubPlay() }
    struct Snapshot { var transport = Transport() }
    var snapshot = Snapshot()
}
private enum TimelineTempo {
    static var lastCursor: Double?
    static func snap(_ time: Double, song: Song, pixelsPerSecond: Double, regionEnds: Bool, cursor: Double, otherCursors: [Double], excludingRegion: UUID?) -> Double {
        lastCursor = cursor
        return time
    }
}
private enum HeaderCounts { static var updates = 0; static var builds = 0 }
private final class HeaderTargetView: NSView { var target = 0; var invoke: (() -> Void)? }
private struct HeaderTarget: NSViewRepresentable {
    let target: Int
    let action: () -> Void
    func makeNSView(context: Context) -> HeaderTargetView { HeaderTargetView() }
    func updateNSView(_ view: HeaderTargetView, context: Context) {
        HeaderCounts.updates += 1; view.target = target; view.invoke = action
    }
}
private struct HeaderScopeFixture: View {
    @ObservedObject var state: HeaderTestState
    var body: some View {
        let viewport = TimelineHeaderViewport.covering(offset: state.offset, width: state.width, height: 500)
        let key = TimelineRenderKey(revision: state.revision, songID: nil, movingClip: nil, movingStart: 0, movingTrack: nil, movingRegion: nil, regionDelta: 0, resizingRegion: nil, resizedStart: 0, resizedEnd: 0)
        let captured = "\(state.project):\(state.name):\(state.locale.identifier):\(state.editing != nil)"
        TimelineStaticHeaderLayer(identity: TimelineStaticHeaderIdentity(controller: ObjectIdentifier(state), project: state.project, renderKey: key,
            documentSize: CGSize(width: 5000, height: 500), viewport: viewport, rulerHeight: 48, extent: 1000, verticalOffset: 0,
            editingRegion: state.editing, unifyingRegion: nil, locale: state.locale)) {
            let _ = { HeaderCounts.builds += 1 }()
            ZStack(alignment: .topLeading) {
                ForEach((0..<44).filter { CGFloat($0) * 75 <= viewport.maxX }, id: \.self) { index in
                    HeaderTarget(target: index) { state.callbackValue = captured; state.edits += 1 }
                        .frame(width: 70, height: 24).offset(x: CGFloat(index) * 75)
                }
            }.frame(width: 5000, height: 500, alignment: .topLeading)
        }.equatable().frame(width: state.width, height: 500, alignment: .leading).clipped()
    }
}
private func targets(_ view: NSView) -> [HeaderTargetView] {
    (view as? HeaderTargetView).map { [$0] } ?? view.subviews.flatMap(targets)
}
MainActor.assumeIsolated {
    _ = NSApplication.shared
    let snapShow = HeaderSnapShow()
    let retainedGesture = HeaderCursorSnapProbe(show: snapShow, editPosition: 10).gesture()
    snapShow.snapshot.transport.editPosition = 42
    retainedGesture()
    precondition(TimelineTempo.lastCursor == 42, "a retained header callback must snap to the current editing needle")
    snapShow.snapshot.transport.editPosition = nil
    snapShow.snapshot.transport.position = 77
    retainedGesture()
    precondition(TimelineTempo.lastCursor == 77, "a retained callback must use the current transport when there is no separate edit position")
    for offset in stride(from: CGFloat(0), through: 2048, by: 63.5) {
        for width in stride(from: CGFloat(0), through: 1600, by: 61.25) {
            let covered = TimelineHeaderViewport.covering(offset: offset, width: width, height: 500)
            precondition(covered.minX <= offset && covered.maxX >= offset + width, "header reserve must cover every exposed pixel")
            for delta: CGFloat in [-512, 511] {
                let actual = max(0, floor(offset / 512) * 512 + delta)
                precondition(covered.minX <= actual && covered.maxX >= actual + width, "header targets must cover subbucket travel and reversal")
            }
            precondition(covered.width <= width + 2048, "header reserve stays bounded")
        }
    }
    let state = HeaderTestState(), window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 550), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: HeaderScopeFixture(state: state)); window.contentView = host
    host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)); host.layoutSubtreeIfNeeded()
    state.width = 761; host.layoutSubtreeIfNeeded()
    let first = targets(host).first { $0.target == 0 }!
    let initialUpdates = HeaderCounts.updates, initialBuilds = HeaderCounts.builds
    for width in 762...799 { state.width = CGFloat(width); host.layoutSubtreeIfNeeded() }
    precondition(HeaderCounts.updates == initialUpdates && HeaderCounts.builds == initialBuilds, "small sidebar changes must retain existing controls and callbacks")
    precondition(targets(host).first { $0.target == 0 } === first, "the hit target must retain identity")
    first.invoke?(); precondition(state.edits == 1 && state.callbackValue.contains("Original"))
    precondition(!targets(host).contains { $0.target == 24 })
    state.width = 1250; host.layoutSubtreeIfNeeded()
    precondition(targets(host).contains { $0.target == 24 }, "crossing a viewport bucket must mount newly exposed targets")
    state.name = "Renamed"; state.revision += 1; host.layoutSubtreeIfNeeded()
    first.invoke?(); precondition(state.callbackValue.contains("Renamed"), "callbacks must update after a project edit")
    let nextProject = UUID(); state.project = nextProject; host.layoutSubtreeIfNeeded()
    first.invoke?(); precondition(state.callbackValue.hasPrefix(nextProject.uuidString), "old project callbacks must not survive switching projects")
    state.editing = UUID(); host.layoutSubtreeIfNeeded()
    first.invoke?(); precondition(state.callbackValue.hasSuffix("true"), "opening an editor must invalidate the header")
    state.locale = Locale(identifier: "pt_BR"); host.layoutSubtreeIfNeeded()
    first.invoke?(); precondition(state.callbackValue.contains("pt_BR"), "language changes must update captured editor locale")
    window.close()
    print("TIMELINE_HEADER_COVERAGE_REUSE_NEW_TARGETS_EDIT_PROJECT_AND_LOCALE_OK")
}
