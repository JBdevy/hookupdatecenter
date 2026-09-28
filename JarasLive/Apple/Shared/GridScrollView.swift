import SwiftUI

/// The grid owns these scroll views. SwiftUI cannot recreate scrollers or reserve gutters.
struct GridScrollView<Content: View>: View {
    let axis: Axis.Set
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    var fileDrop: (([URL], CGPoint) -> Bool)? = nil
    var fileDropPreview: ((CGPoint?) -> Void)? = nil
    @ViewBuilder let content: () -> Content
    var body: some View {
        #if os(macOS)
        NativeGridScroll(horizontal: axis == .horizontal, contentWidth: contentWidth, contentHeight: contentHeight, fileDrop: fileDrop, fileDropPreview: fileDropPreview, content: content())
        #else
        ScrollView(axis, showsIndicators: false, content: content)
        #endif
    }
}
#if os(macOS)
import AppKit
private struct NativeGridScroll<Content: View>: NSViewRepresentable {
    final class Coordinator {
        let actions = GridHostedActions()
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    let horizontal: Bool
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    let fileDrop: (([URL], CGPoint) -> Bool)?
    let fileDropPreview: ((CGPoint?) -> Void)?
    let content: Content
    @Environment(\.openFX) private var openFX
    @Environment(\.openClipFXChain) private var openClipFXChain
    @Environment(\.editTextItem) private var editTextItem
    @Environment(\.gridInteractionBlocked) private var gridInteractionBlocked
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    private func hosted(_ actions: GridHostedActions) -> GridHostedContent<Content> {
        actions.fx = openFX; actions.clipFX = openClipFXChain; actions.text = editTextItem
        return GridHostedContent(content: content, openFX: actions.openFX, openClipFXChain: actions.openClipFX, editTextItem: actions.editText, gridInteractionBlocked: gridInteractionBlocked, locale: locale, colorScheme: colorScheme)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GridNativeScrollView, context: Context) -> CGSize? {
        // The parent supplies the viewport. Asking AppKit to measure the entire
        // document during every zoom tick also remeasures all mixer controls.
        CGSize(width: proposal.width ?? contentWidth, height: proposal.height ?? contentHeight)
    }
    func makeNSView(context: Context) -> GridNativeScrollView {
        let scroll = GridNativeScrollView()
        if horizontal { scroll.contentView = TimelineClipView() }
        if horizontal { scroll.registerForDraggedTypes([.fileURL]) }
        scroll.fileDrop = fileDrop
        scroll.fileDropPreview = fileDropPreview
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        // The timeline has an explicit document size; do not let hosting intrinsic
        // sizing temporarily collapse it while SwiftUI updates zoom or playback.
        let host = GridHostingView(rootView: hosted(context.coordinator.actions))
        host.sizingOptions = []
        host.setFrameSize(NSSize(width: contentWidth, height: contentHeight))
        scroll.contentView.copiesOnScroll = false
        let document = GridDocumentView(frame: host.frame)
        document.host = host; document.addSubview(host)
        scroll.documentView = document
        return scroll
    }
    func updateNSView(_ scroll: GridNativeScrollView, context: Context) {
        guard let document = scroll.documentView as? GridDocumentView, let host = document.host as? GridHostingView<GridHostedContent<Content>> else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        scroll.fileDrop = fileDrop
        scroll.fileDropPreview = fileDropPreview
        host.rootView = hosted(context.coordinator.actions)
        let size = NSSize(width: contentWidth, height: contentHeight)
        if host.frame.size != size {
            document.setFrameSize(size)
            host.setFrameSize(size)
            host.needsLayout = true
            host.needsDisplay = true
            scroll.contentView.needsDisplay = true
        }
        scroll.applyZoomAnchor()
    }
}
/// Stable environment actions prevent a document-size change from invalidating
/// every menu/button that reads these actions. The handlers still stay current.
private final class GridHostedActions {
    var fx: (UUID?, String) -> Void = { _, _ in }
    var clipFX: (UUID) -> Void = { _ in }
    var text: (UUID) -> Void = { _ in }
    lazy var openFX: (UUID?, String) -> Void = { [weak self] in self?.fx($0, $1) }
    lazy var openClipFX: (UUID) -> Void = { [weak self] in self?.clipFX($0) }
    lazy var editText: (UUID) -> Void = { [weak self] in self?.text($0) }
}
private struct GridHostedContent<Content: View>: View {
    let content: Content
    let openFX: (UUID?, String) -> Void
    let openClipFXChain: (UUID) -> Void
    let editTextItem: (UUID) -> Void
    let gridInteractionBlocked: Bool
    let locale: Locale
    let colorScheme: ColorScheme
    var body: some View {
        content.environment(\.openFX, openFX).environment(\.openClipFXChain, openClipFXChain)
            .environment(\.editTextItem, editTextItem)
            .environment(\.gridInteractionBlocked, gridInteractionBlocked)
            .environment(\.locale, locale).environment(\.colorScheme, colorScheme)
    }
}
/// Explicit document geometry terminates AppKit fitting-size propagation here.
/// Rescaling the timeline must not ask the track controls and meters for sizes.
private final class GridDocumentView: NSView {
    var host: NSView?
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var fittingSize: NSSize { frame.size }
}
private final class GridHostingView<Content: View>: NSHostingView<Content> {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var fittingSize: NSSize { frame.size }
}
final class GridNativeScrollView: NSScrollView {
    var fileDrop: (([URL], CGPoint) -> Bool)?
    var fileDropPreview: ((CGPoint?) -> Void)?
    var fileDropModifierFlags: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    private var lastFileDropPreview: CGPoint?
    private var lastFileDropModifierFlags: NSEvent.ModifierFlags = []
    private func updateFileDropPreview(_ point: CGPoint?) {
        // Shift changes magnetic snapping even when the dragged file has not moved.
        let modifiers: NSEvent.ModifierFlags = point == nil ? [] : fileDropModifierFlags()
        guard point != lastFileDropPreview || (point != nil && modifiers != lastFileDropModifierFlags) else { return }
        lastFileDropPreview = point
        lastFileDropModifierFlags = modifiers
        fileDropPreview?(point)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard fileDrop != nil, let documentView,
              sender.draggingSourceOperationMask.contains(.copy),
              sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else {
            updateFileDropPreview(nil)
            return []
        }
        updateFileDropPreview(documentView.convert(sender.draggingLocation, from: nil))
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { updateFileDropPreview(nil) }
    override func draggingEnded(_ sender: NSDraggingInfo) { updateFileDropPreview(nil) }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { updateFileDropPreview(nil) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { updateFileDropPreview(nil) }
        guard let documentView, let fileDrop,
              sender.draggingSourceOperationMask.contains(.copy),
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        return fileDrop(urls, documentView.convert(sender.draggingLocation, from: nil))
    }

    var zoomAnchor: (fraction: Double, screenX: CGFloat, width: CGFloat)?
    func applyZoomAnchor() {
        guard let anchor = zoomAnchor, let document = documentView,
              abs(document.frame.width - anchor.width) < 2 else { return }
        var origin = contentView.bounds.origin
        origin.x = min(max(0, CGFloat(anchor.fraction) * document.frame.width - anchor.screenX),
                       max(0, document.frame.width - contentView.bounds.width))
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
        zoomAnchor = nil
    }

    override var hasHorizontalScroller: Bool {
        get { false }
        set { super.hasHorizontalScroller = false }
    }
    override var hasVerticalScroller: Bool {
        get { false }
        set { super.hasVerticalScroller = false }
    }
    override func tile() {
        super.tile()
        // No border, scroller, or accessory area: the clip fills the entire viewport.
        if contentView.frame != bounds { contentView.frame = bounds }
    }
}
#endif

#if os(macOS)
/// Time zero is the hard left boundary for both trackpad scrolling and zoom.
private final class TimelineClipView: NSClipView {
    private func boundedOrigin(_ origin: NSPoint) -> NSPoint {
        var result = origin
        let maximum = max(0, (documentView?.frame.width ?? 0) - bounds.width)
        result.x = min(maximum, max(0, origin.x))
        return result
    }
    // Momentum scrolling can update bounds directly, bypassing the proposed
    // rectangle constraint. Enforce time zero on both AppKit entry points.
    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(boundedOrigin(newOrigin))
    }
    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: boundedOrigin(newOrigin))
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        let maximum = max(0, (documentView?.frame.width ?? 0) - proposedBounds.width)
        constrained.origin.x = min(max(0, proposedBounds.minX), maximum)
        return constrained
    }
}
#endif

#if os(macOS)
struct NativeTimelinePinnedLayer<Content: View>: NSViewRepresentable {
    let width: CGFloat
    let height: CGFloat
    var pinHorizontally = false
    let content: Content
    @Environment(\.locale) private var locale
    func makeNSView(context: Context) -> NativeTimelinePinnedView {
        NativeTimelinePinnedView()
    }
    func updateNSView(_ view: NativeTimelinePinnedView, context: Context) {
        view.pinHorizontally = pinHorizontally
        let root = AnyView(content.environment(\.locale, locale))
        if let host = view.host as? NSHostingView<AnyView> {
            host.rootView = root
        } else {
            let host = NSHostingView(rootView: root)
            host.sizingOptions = []
            view.host?.removeFromSuperview()
            view.host = host
            view.addSubview(host)
        }
        view.host?.setFrameSize(NSSize(width: width, height: height))
        view.observeScroll()
    }
}
final class NativeTimelinePinnedView: NSView {
    var host: NSView?
    var pinHorizontally = false
    private weak var clip: NSClipView?
    private weak var horizontalClip: NSClipView?
    private var observer: NSObjectProtocol?
    private var horizontalObserver: NSObjectProtocol?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self || hit === host ? nil : hit
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeScroll()
    }
    func observeScroll() {
        var parent = superview
        var outer: NSScrollView?
        var inner: NSScrollView?
        while let view = parent {
            if let scroll = view as? GridNativeScrollView {
                if inner == nil { inner = scroll }
                outer = scroll
            }
            parent = view.superview
        }
        guard let next = outer?.contentView else { return }
        if clip !== next {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            clip = next
            next.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: next, queue: .main) { [weak self] _ in
                self?.pin()
            }
        }
        let nextHorizontal = pinHorizontally && inner !== outer ? inner?.contentView : nil
        if horizontalClip !== nextHorizontal {
            if let horizontalObserver { NotificationCenter.default.removeObserver(horizontalObserver) }
            horizontalObserver = nil
            horizontalClip = nextHorizontal
            if let nextHorizontal {
                nextHorizontal.postsBoundsChangedNotifications = true
                horizontalObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: nextHorizontal, queue: .main) { [weak self] _ in
                    self?.pin()
                }
            }
        }
        pin()
    }
    private func pin() {
        guard let host, let clip else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let origin = NSPoint(x: max(0, horizontalClip?.bounds.minX ?? 0), y: max(0, clip.bounds.minY))
        if host.frame.origin != origin { host.setFrameOrigin(origin) }
        CATransaction.commit()
    }
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let horizontalObserver { NotificationCenter.default.removeObserver(horizontalObserver) }
    }
}
#endif
