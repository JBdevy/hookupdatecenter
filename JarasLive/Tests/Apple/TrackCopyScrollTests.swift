// Shares the native workspace fixture's window and layout helpers.
@MainActor private final class TrackCopyScrollState: ObservableObject {
    @Published var count = 4
    @Published var request: GridRowReveal?
    @Published var pulse = 0
    func paste(_ count: Int = 1) {
        self.count += count
        request = GridRowReveal(id: UUID(), offset: CGFloat(self.count - 1) * 64,
                                height: 64, headerHeight: 96)
    }
}
private struct TrackCopyScrollFixture: View {
    @ObservedObject var state: TrackCopyScrollState
    var body: some View {
        let count = state.count, request = state.request, pulse = state.pulse
        TimelineGeometryReader { geometry in
            let height = max(geometry.size.height, 96 + CGFloat(count + 2) * 64)
            GridScrollView(axis: .vertical, contentWidth: geometry.size.width, contentHeight: height,
                           trackHeight: 64, rowHeights: Array(repeating: 64, count: count),
                           selectedRow: count - 1, rowReveal: request) {
                HStack(spacing: 0) {
                    Color.gray.frame(width: 200)
                    Text("Grid \(pulse)").frame(maxWidth: .infinity)
                }.frame(height: height)
            }.frame(maxWidth: .infinity).frame(height: geometry.size.height)
        }
    }
}
MainActor.assumeIsolated {
    let state = TrackCopyScrollState()
    state.count = 12
    let root = NSHostingView(rootView: TrackCopyScrollFixture(state: state))
    let window = NSWindow(contentRect: CGRect(x: -5000, y: -5000, width: 1000, height: 500),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = root; settle(root)
    let scroll = descendants(GridNativeScrollView.self, in: root).first!
    // Both direct momentum bounds and explicit navigation must prepare pixels
    // before exposure, exactly once per movement (not again through AppKit's
    // internal scroll(to:) -> setBoundsOrigin dispatch).
    let clip = scroll.contentView
    var prepared: [(CGFloat, CGFloat)] = []
    scroll.prepareHostedVerticalScroll = { destination in
        prepared.append((destination, clip.bounds.minY)); return false
    }
    clip.scroll(to: CGPoint(x: 0, y: 32))
    precondition(prepared.count == 1 && prepared[0].0 == 32 && prepared[0].1 == 0)
    clip.scroll(to: CGPoint(x: 0, y: 32))
    precondition(prepared.count == 1, "Unchanged navigation must not rebuild viewport content")
    clip.setBoundsOrigin(CGPoint(x: 0, y: 48))
    precondition(prepared.count == 2 && prepared[1].0 == 48 && prepared[1].1 == 32)
    scroll.anchorTrackHeight(to: CGPoint(x: 0, y: 64))
    precondition(prepared.count == 3 && prepared[2].0 == 64 && prepared[2].1 == 48,
                 "Height anchoring must still publish its destination before moving the clip")
    clip.scroll(to: .zero)
    scroll.prepareHostedVerticalScroll = nil
    @MainActor func check() {
        let visible = scroll.contentView.bounds, request = state.request!
        precondition(request.offset >= visible.minY - 0.5)
        precondition(request.offset + request.height + request.headerHeight <= visible.maxY + 0.5,
                     "Newest row must be fully visible after a native document update: \(request) / \(visible)")
    }
    for index in 0..<200 {
        state.paste()
        if index % 4 == 0 { settle(root); check() }
    }
    settle(root); check()
    // An ordinary render must respect manual scrolling; only another insertion
    // requests following the selection again.
    scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
    state.pulse += 1; settle(root)
    precondition(scroll.contentView.bounds.minY == 0)
    state.paste(3); settle(root); check()
    window.setContentSize(CGSize(width: 1200, height: 450)); settle(root)
    state.paste(); settle(root); check()
    // A request arriving before the document grows must remain pending.
    let future = GridRowReveal(id: UUID(), offset: 25000, height: 64, headerHeight: 96)
    scroll.revealRow(future)
    scroll.documentView!.setFrameSize(CGSize(width: 1200, height: 26000))
    scroll.commitHostedProjection()
    precondition(scroll.contentView.bounds.maxY >= 25160)
    window.contentView = nil; window.close()
    print("TRACK_COPY_NATIVE_VERTICAL_FOLLOW_200_REPEATS_OK")
}
