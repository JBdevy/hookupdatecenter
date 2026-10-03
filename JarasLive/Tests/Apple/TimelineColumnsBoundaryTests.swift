private enum ColumnsProbeCounts {
    static var created = 0
    static var removed = 0
}
private final class ColumnsControlView: NSView {
    override init(frame: NSRect) {
        ColumnsProbeCounts.created += 1
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }
}
private struct ColumnsControlProbe: NSViewRepresentable {
    let revision: Int
    func makeNSView(context: Context) -> ColumnsControlView { ColumnsControlView(frame: .zero) }
    func updateNSView(_ view: ColumnsControlView, context: Context) {}
    static func dismantleNSView(_ view: ColumnsControlView, coordinator: Void) { ColumnsProbeCounts.removed += 1 }
}
private final class ColumnsZoom: ObservableObject { @Published var documentWidth: CGFloat = 2400 }
private final class ColumnsDimensions: ObservableObject {
    @Published var mixerWidth: CGFloat = 220
    @Published var height: CGFloat = 800
    @Published var revision = 0
    @Published var project = UUID()
}
private struct ColumnsBlankDocument: View {
    let width: CGFloat
    let height: CGFloat
    var body: some View { Color.clear.frame(width: width, height: height) }
}
private final class ColumnsHorizontalScroll: NSScrollView {
    let hosted = GridHostingView(rootView: ColumnsBlankDocument(width: 2400, height: 800))
    let document = GridDocumentView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        if #available(macOS 13, *) { hosted.sizingOptions = [] }
        document.host = hosted
        document.addSubview(hosted)
        documentView = document
        hosted.layoutProfile = TimelineLayoutDiagnostics.make("fixture-horizontal")
    }
    required init?(coder: NSCoder) { fatalError() }
}
private struct ColumnsHorizontalDocument: NSViewRepresentable {
    let width: CGFloat
    let height: CGFloat
    func makeNSView(context: Context) -> ColumnsHorizontalScroll { ColumnsHorizontalScroll(frame: .zero) }
    func updateNSView(_ view: ColumnsHorizontalScroll, context: Context) {
        view.hosted.rootView = ColumnsBlankDocument(width: width, height: height)
        view.document.setFrameSize(CGSize(width: width, height: height))
        view.hosted.setFrameSize(CGSize(width: width, height: height))
        view.hosted.needsLayout = true
    }
    @available(macOS 13, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ColumnsHorizontalScroll, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? height)
    }
}
private struct ColumnsZoomContent: View {
    @ObservedObject var zoom: ColumnsZoom
    let height: CGFloat
    var body: some View {
        ColumnsHorizontalDocument(width: zoom.documentWidth, height: height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
private struct ColumnsFixture: View {
    @ObservedObject var dimensions: ColumnsDimensions
    let zoom: ColumnsZoom
    var body: some View {
        NativeTimelineColumns(mixerWidth: dimensions.mixerWidth, viewportWidth: 800, height: dimensions.height,
            dividerWidth: 4, project: dimensions.project, mixerIdentity: dimensions.revision) {
            ColumnsControlProbe(revision: dimensions.revision)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } divider: {
            Color.gray
        } timeline: {
            ColumnsZoomContent(zoom: zoom, height: dimensions.height)
        }.frame(width: 800, height: dimensions.height)
    }
}
private func columnsDescendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(columnsDescendants)
}
MainActor.assumeIsolated {
    _ = NSApplication.shared
    let dimensions = ColumnsDimensions(), zoom = ColumnsZoom()
    let outer = NSScrollView(frame: CGRect(x: 0, y: 0, width: 800, height: 320))
    let document = GridHostingView(rootView: ColumnsFixture(dimensions: dimensions, zoom: zoom))
    let verticalDocument = GridDocumentView()
    verticalDocument.host = document
    verticalDocument.addSubview(document)
    if #available(macOS 13, *) { document.sizingOptions = [] }
    document.setFrameSize(CGSize(width: 800, height: 800))
    verticalDocument.setFrameSize(document.frame.size)
    document.layoutProfile = TimelineLayoutDiagnostics.make("fixture-vertical")
    outer.documentView = verticalDocument
    let window = NSWindow(contentRect: outer.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = outer
    window.orderFront(nil)
    func settle() {
        for _ in 0..<3 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.012))
        }
    }
    settle()
    func boundaryHosts() -> [String: NSView] {
        Dictionary(uniqueKeysWithValues: columnsDescendants(document).compactMap { view in
            guard let name = view.identifier?.rawValue, name.hasPrefix("columns-") else { return nil }
            return (name, view)
        })
    }
    let hosts = boundaryHosts()
    precondition(hosts.count == 3)
    let originals = hosts.mapValues(ObjectIdentifier.init)
    let created = ColumnsProbeCounts.created
    let mixer = hosts["columns-mixer"]!, timeline = hosts["columns-timeline"]!
    let mixerFrame = mixer.frame
    let rootsBefore = TimelineLayoutDiagnostics.roots["columns-mixer", default: 0]
    TimelineLayoutDiagnostics.layouts.removeAll()
    for width: CGFloat in [2500, 2700, 3100, 2900, 2600, 2400] {
        zoom.documentWidth = width
        settle()
        precondition(mixer.frame == mixerFrame, "zoom cannot resize or reposition the mixer host")
        precondition(boundaryHosts().mapValues(ObjectIdentifier.init) == originals, "zoom preserves all native hosting identities")
    }
    precondition(TimelineLayoutDiagnostics.roots["columns-mixer", default: 0] == rootsBefore,
        "zoom must not assign a new mixer root")
    precondition(TimelineLayoutDiagnostics.layouts["columns-mixer", default: 0] == 0,
        "the independent zoom subtree must not trigger mixer layout")
    precondition(TimelineLayoutDiagnostics.layouts["columns-timeline", default: 0] > 0,
        "the test must exercise timeline layout during zoom")
    let zoomLayouts = TimelineLayoutDiagnostics.layouts
    for height: CGFloat in [1200, 640, 900] {
        dimensions.height = height
        verticalDocument.setFrameSize(CGSize(width: 800, height: height))
        document.setFrameSize(CGSize(width: 800, height: height))
        settle()
        precondition(mixer.frame.height == height && timeline.frame.height == height,
            "track-height changes keep both sibling documents aligned")
        precondition(mixer.frame.minY == timeline.frame.minY)
    }
    outer.contentView.scroll(to: CGPoint(x: 0, y: 150))
    settle()
    let mixerY = mixer.convert(.zero, to: outer.contentView).y
    let timelineY = timeline.convert(.zero, to: outer.contentView).y
    precondition(abs(mixerY - timelineY) < 0.1, "both hosts inherit the same vertical scroll offset")
    dimensions.mixerWidth = 0
    settle()
    precondition(mixer.isHidden && timeline.frame.minX == 4 && timeline.frame.width == 796)
    dimensions.mixerWidth = 280
    dimensions.revision += 1
    settle()
    precondition(!mixer.isHidden && mixer.frame.width == 280 && timeline.frame.minX == 284)
    dimensions.project = UUID()
    settle()
    precondition(TimelineLayoutDiagnostics.roots["columns-mixer", default: 0] > rootsBefore,
        "edits and project changes must update mixer content")
    precondition(boundaryHosts().mapValues(ObjectIdentifier.init) == originals,
        "height, width, collapse and project changes preserve native hosting identities")
    precondition(ColumnsProbeCounts.created == created && ColumnsProbeCounts.removed == 0,
        "mixer controls remain mounted through all geometry changes")
    window.orderOut(nil)
    print("TIMELINE_COLUMNS_HOST_IDENTITY_ZOOM_ISOLATION_AND_HEIGHT_SCROLL_ALIGNMENT_OK zoomLayouts=\(zoomLayouts)")
}
