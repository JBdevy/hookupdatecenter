private final class HorizontalState: ObservableObject {
    @Published var x: CGFloat = 0
    @Published var focus: CGFloat?
}
private final class FocusAction { var perform: (CGFloat) -> Void = { _ in } }
private final class FocusProbeView: NSView { var previous: CGFloat? }
private struct FocusProbe: NSViewRepresentable {
    let value: CGFloat?
    let action: FocusAction
    func makeNSView(context: Context) -> FocusProbeView { FocusProbeView() }
    func updateNSView(_ view: FocusProbeView, context: Context) {
        if let value, value != view.previous { view.previous = value; action.perform(value) }
    }
}
private enum HorizontalProbe {
    static var mounted = CGRect.zero
    static var waveform = CGRect.zero
}
private struct MountedCoverage: NSViewRepresentable {
    let rect: CGRect
    let waveform: CGRect
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        HorizontalProbe.mounted = rect; HorizontalProbe.waveform = waveform
    }
}
private struct HorizontalFixture: View {
    @ObservedObject var state: HorizontalState
    let tiled: Bool
    let focus: FocusAction
    var body: some View {
        let viewport = CGRect(x: state.x, y: 0, width: 840, height: 500)
        let size = CGSize(width: 30000, height: 500)
        ViewportTimelineCanvas(visibleRect: viewport, synchronized: true, documentWidth: size.width,
            identity: TimelineTileIdentity(), tileIdentity: tiled ? { _, _ in TimelineTileIdentity() } : nil) { context, _, rect, _ in
                context.fill(Path(rect), with: .color(.green))
            }
            .background(MountedCoverage(rect: TimelineCanvasCoverage.preparedRect(visibleRect: viewport, documentSize: size),
                waveform: TimelineWaveformCoverage.preparedRect(visibleRect: viewport, documentSize: size)))
            .background(FocusProbe(value: state.focus, action: focus))
            .frame(width: size.width, height: size.height)
    }
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    for tiled in [false, true] {
        let state = HorizontalState()
        let focus = FocusAction()
        let scroll = GridNativeScrollView(frame: NSRect(x: 0, y: 0, width: 840, height: 500))
        scroll.contentView = TimelineClipView()
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.horizontalScrollElasticity = .none; scroll.verticalScrollElasticity = .none
        let host = GridHostingView(rootView: HorizontalFixture(state: state, tiled: tiled, focus: focus))
        host.sizingOptions = []; host.frame = CGRect(x: 0, y: 0, width: 30000, height: 500)
        let document = GridDocumentView(frame: host.frame)
        document.autoresizesSubviews = false; document.host = host; document.addSubview(host)
        scroll.documentView = document
        let wheel = TimelineWheelView(frame: document.bounds)
        focus.perform = { [weak wheel] x in wheel?.focus(request: UUID(), x: x) }
        document.addSubview(wheel)
        var publications = 0, publishedBeforeMove = true
        wheel.horizontalOffsetChanged = { offset in
            publications += 1
            // Every deliberate jump below changes buckets. This callback must
            // run before the actual clip exposes the requested destination.
            if floor(scroll.contentView.bounds.minX / 512) * 512 == offset { publishedBeforeMove = false }
            state.x = offset
        }
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll; window.orderFront(nil)
        for _ in 0..<3 { document.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        wheel.observeHorizontalScroll()
        func checkFirstDisplay() {
            let actual = CGRect(x: scroll.contentView.bounds.minX, y: 0, width: 840, height: 500)
            precondition(HorizontalProbe.mounted.contains(actual), "destination content must mount in this event before first display")
            precondition(HorizontalProbe.waveform.contains(actual), "smaller waveform reserve must also mount before the native clip moves")
            precondition(HorizontalProbe.mounted.width <= 840 + 2048, "a jump must not mount the intervening project")
            // Render immediately: no RunLoop turn, queued callback, sleep or
            // settle helper may repair a blank first frame for this assertion.
            let bitmap = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds)!
            scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
            for fraction: CGFloat in [0.03, 0.5, 0.97] {
                let color = bitmap.colorAt(x: Int(CGFloat(bitmap.pixelsWide - 1) * fraction), y: bitmap.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
                precondition(color.greenComponent > color.redComponent + 0.15 && color.alphaComponent > 0.9, "first visible frame must contain the destination canvas")
            }
        }
        for x: CGFloat in [20480, 512, 25088, 1024, 0, 15360] {
            let previous = publications
            publishedBeforeMove = true
            scroll.contentView.scroll(to: NSPoint(x: x, y: 0))
            precondition(state.x == floor(x / 512) * 512 && publications == previous + 1)
            precondition(publishedBeforeMove, "native preparation must precede changing clip bounds")
            checkFirstDisplay()
        }
        let previous = publications
        scroll.contentView.scroll(to: NSPoint(x: 15400, y: 0))
        precondition(publications == previous, "subbucket movement must reuse existing coverage")
        checkFirstDisplay()
        state.focus = 24000
        document.layoutSubtreeIfNeeded()
        precondition(scroll.contentView.bounds.minX > 23000, "focus from a SwiftUI update must reveal its destination")
        checkFirstDisplay()
        publishedBeforeMove = true
        scroll.contentView.setBoundsOrigin(NSPoint(x: 2048, y: 0))
        precondition(publishedBeforeMove && state.x == 2048, "native direct bounds changes use the same preparation")
        checkFirstDisplay()
        window.orderOut(nil)
    }
    print("TIMELINE_HORIZONTAL_NATIVE_JUMP_FIRST_FRAME_COVERAGE_AND_PIXELS_OK")
}
