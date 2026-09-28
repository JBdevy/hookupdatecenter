#if os(macOS)
import SwiftUI
import AppKit
import QuartzCore

/// Observes only wheel events over this timeline; clicks and playhead drags pass through.
struct TimelineWheelInput: NSViewRepresentable {
    @Binding var zoom: Double
    let position: Double
    let extend: () -> Void
    let horizontalOffsetChanged: (CGFloat) -> Void
    let verticalOffsetChanged: (CGFloat) -> Void
    let focusRequest: UUID
    let focusX: CGFloat?
    var interactionBlocked = false
    var changeTrackHeight: (Double) -> Void = { _ in }
    func makeNSView(context: Context) -> TimelineWheelView { TimelineWheelView() }
    func updateNSView(_ view: TimelineWheelView, context: Context) {
        view.horizontalOffsetChanged = horizontalOffsetChanged
        view.interactionBlocked = interactionBlocked
        view.changeTrackHeight = { factor in
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { changeTrackHeight(factor) }
        }
        view.observeHorizontalScroll()
        view.verticalOffsetChanged = verticalOffsetChanged
        view.observeVerticalScroll()
        view.extend = extend
        view.acceptRenderedZoom(zoom)
        view.position = position
        view.changeZoom = { next, offset in
            // Prepare the destination tiles in the same SwiftUI update as scale.
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                horizontalOffsetChanged(floor(offset / 512) * 512)
                zoom = next
            }
        }
        view.focus(request: focusRequest, x: focusX)
    }
}
final class TimelineWheelView: NSView, NativeTimelineInputObserver {
    var interactionBlocked = false { didSet { if interactionBlocked && !oldValue { stopZoomUpdates() } } }
    var horizontalOffsetChanged: ((CGFloat) -> Void)?
    private weak var observedHorizontal: NSClipView?
    private var horizontalObserver: NSObjectProtocol?
    private var lastHorizontalBucket: CGFloat?
    private var horizontalNotificationPending = false
    func observeHorizontalScroll() {
        guard let clip = scrollViews.first?.contentView, observedHorizontal !== clip else { return }
        if let horizontalObserver { NotificationCenter.default.removeObserver(horizontalObserver) }
        observedHorizontal = clip
        clip.postsBoundsChangedNotifications = true
        horizontalObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self, weak clip] _ in
            guard let self, let clip else { return }
            let bucket = floor(clip.bounds.minX / 512) * 512
            guard self.lastHorizontalBucket != bucket, !self.horizontalNotificationPending else { return }
            self.horizontalNotificationPending = true
            DispatchQueue.main.async { [weak self, weak clip] in
                guard let self else { return }
                self.horizontalNotificationPending = false
                guard let clip else { return }
                // Read the latest origin, never publish a queued stale position.
                if let grid = clip.superview as? GridNativeScrollView, grid.zoomAnchor != nil { return }
                let bucket = floor(clip.bounds.minX / 512) * 512
                guard self.lastHorizontalBucket != bucket else { return }
                self.lastHorizontalBucket = bucket
                self.horizontalOffsetChanged?(bucket)
            }
        }
    }
    var verticalOffsetChanged: ((CGFloat) -> Void)?
    private weak var observedClip: NSClipView?
    private var boundsObserver: NSObjectProtocol?
    func observeVerticalScroll() {
        guard let clip = scrollViews.dropFirst().first?.contentView, observedClip !== clip else { return }
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        observedClip = clip
        clip.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self, weak clip] _ in
            guard let self, let clip else { return }
            self.verticalOffsetChanged?(max(0, clip.bounds.minY))
        }
    }
    var extend: (() -> Void)?
    var zoom = 1.0
    var position = 0.0
    var changeZoom: ((Double, CGFloat) -> Void)?
    var changeTrackHeight: ((Double) -> Void)?
    func acceptRenderedZoom(_ value: Double) {
        // An older SwiftUI update must not replace the next scale already requested.
        if !zoomRunning { zoom = value }
    }
    private var gestureAnchor: Double?
    private var pendingZoom: Double?
    private var zoomTimer: Timer?
    private var cancelDisplayLink: (() -> Void)?
    private var zoomRunning: Bool { zoomTimer != nil || cancelDisplayLink != nil }
    private weak var zoomGrid: GridNativeScrollView?
    private var lastZoomInput = 0.0
    private var lastZoomFrame = 0.0
    private var zoomDirection = 0.0
    private var documentUnitWidth = 1.0
    private var lastFocusRequest: UUID?
    func focus(request: UUID, x: CGFloat?) {
        guard lastFocusRequest != request else { return }
        lastFocusRequest = request
        guard let x else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let horizontal = self.scrollViews.first else { return }
            self.window?.contentView?.layoutSubtreeIfNeeded()
            guard self.lastFocusRequest == request else { return }
            let visible = horizontal.contentView.bounds
            // User-selected left limit: the region start is 14 points inside the grid.
            // At time zero there is no negative timeline available for that inset.
            let leftInset: CGFloat = 14
            let requiredStart = visible.minX + min(leftInset, x)
            // Right limit captured from the user's Música 3 position: 547/1003
            // of the visible grid width. Preserve that proportion when resizing.
            let rightLimit = visible.minX + max(leftInset, visible.width * (547.0 / 1003.0))
            if x < requiredStart - 0.5 {
                self.scroll(horizontal, x: max(0, x - leftInset))
            } else if x > rightLimit + 0.5 {
                let rightInset = rightLimit - visible.minX
                self.scroll(horizontal, x: max(0, x - rightInset))
            }
            // Restoring a project can scroll before the bounds observer attaches.
            // Publish the final viewport as well, so its tiles are ready at startup.
            let bucket = floor(horizontal.contentView.bounds.minX / 512) * 512
            self.lastHorizontalBucket = bucket
            self.horizontalOffsetChanged?(bucket)
        }
    }
    private var monitor: Any?
    private var trackpadHorizontal: Bool?
    private var horizontalLimiter = HorizontalScrollLimiter()
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopZoomUpdates() }
        DispatchQueue.main.async { [weak self] in self?.observeVerticalScroll(); self?.observeHorizontalScroll() }
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if window != nil {
            NativeTimelineInputGate.shared.add(self)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleWheelEvent(event) == true ? nil : event
            }
        }
    }
    func timelineInputGateChanged(blocked: Bool) {
        if blocked { stopZoomUpdates(); trackpadHorizontal = nil }
    }
    @discardableResult func handleWheelEvent(_ event: NSEvent) -> Bool {
        guard !interactionBlocked, !NativeTimelineInputGate.shared.isBlocked(window),
              event.window === window, window != nil, window?.attachedSheet == nil,
              visibleRect.contains(convert(event.locationInWindow, from: nil)) else { return false }
        return handle(event)
    }
    deinit { cancelDisplayLink?(); zoomTimer?.invalidate(); if let horizontalObserver { NotificationCenter.default.removeObserver(horizontalObserver) }; if let monitor { NSEvent.removeMonitor(monitor) }; if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) } }
    private var scrollViews: [NSScrollView] {
        var result: [NSScrollView] = []
        var parent = superview
        while let view = parent {
            if let scroll = view as? NSScrollView { result.append(scroll) }
            parent = view.superview
        }
        return result
    }
    private func scroll(_ view: NSScrollView, x: CGFloat? = nil, y: CGFloat? = nil) {
        guard let document = view.documentView else { return }
        let clip = view.contentView
        var origin = clip.bounds.origin
        if let x { origin.x = min(max(0, x), max(0, document.frame.width - clip.bounds.width)) }
        if let y { origin.y = min(max(0, y), max(0, document.frame.height - clip.bounds.height)) }
        clip.scroll(to: origin)
        view.reflectScrolledClipView(clip)
    }
    private func handle(_ event: NSEvent) -> Bool {
        let views = scrollViews
        guard let horizontal = views.first else { return false }
        let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
        let movement = delta * (event.hasPreciseScrollingDeltas ? 1 : 18)
        if !event.modifierFlags.intersection([.command, .control]).isEmpty {
            stopZoomUpdates()
            if event.momentumPhase.isEmpty, event.scrollingDeltaY != 0 {
                let amount = Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.004 : 0.06)
                changeTrackHeight?(exp(min(0.08, max(-0.08, amount))))
            }
        } else if event.modifierFlags.contains(.shift) {
            stopZoomUpdates()
            let limited = horizontalLimiter.limit(movement, timestamp: event.timestamp, begins: event.phase.contains(.began))
            let target = horizontal.contentView.bounds.minX - limited
            if let document = horizontal.documentView, target + horizontal.contentView.bounds.width > document.frame.width - 160 { extend?() }
            scroll(horizontal, x: target)
        } else if event.hasPreciseScrollingDeltas && (!event.phase.isEmpty || !event.momentumPhase.isEmpty) {
            // Use the trackpad's own momentum deltas, with a time-based speed
            // ceiling. Do not queue excess distance or run an idle animation timer.
            if event.phase.contains(.began) || trackpadHorizontal == nil {
                if event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
                    trackpadHorizontal = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
                }
            }
            if trackpadHorizontal == true {
                stopZoomUpdates()
                let limited = horizontalLimiter.limit(event.scrollingDeltaX, timestamp: event.timestamp, begins: event.phase.contains(.began))
                let target = horizontal.contentView.bounds.minX - limited
                if event.scrollingDeltaX < 0, let document = horizontal.documentView,
                   target + horizontal.contentView.bounds.width > document.frame.width - 300 { extend?() }
                scroll(horizontal, x: target)
            } else {
                applyWheelZoom(event, delta: event.scrollingDeltaY, horizontal: horizontal)
            }
            if event.momentumPhase.contains(.ended) || event.phase.contains(.cancelled) { trackpadHorizontal = nil }
        } else {
            applyWheelZoom(event, delta: event.scrollingDeltaY, horizontal: horizontal)
        }
        return true
    }
    private func applyWheelZoom(_ event: NSEvent, delta: CGFloat, horizontal: NSScrollView) {
        // Zoom follows finger motion only. Native momentum remains available
        // for panning, but must not keep changing scale after release.
        guard event.momentumPhase.isEmpty else { return }
        guard delta != 0, let grid = horizontal as? GridNativeScrollView,
              let document = horizontal.documentView else { return }
        let direction = delta > 0 ? 1.0 : -1.0
        if zoomDirection != 0 && direction != zoomDirection { pendingZoom = zoom }
        zoomDirection = direction
        let base = pendingZoom ?? zoom
        let next = min(TimelineZoomLimits.maximum, max(TimelineZoomLimits.minimum, base * exp(Double(delta) * (event.hasPreciseScrollingDeltas ? 0.008 : 0.09))))
        guard next != base else { return }
        pendingZoom = next
        lastZoomInput = ProcessInfo.processInfo.systemUptime
        // Start on the input event, then interpolate on display frames with a
        // short time constant. Reversing discards the previous pending direction.
        if zoomRunning { return }
        documentUnitWidth = (grid.zoomAnchor?.width ?? document.frame.width) / zoom
        gestureAnchor = min(1, max(0, position))
        scroll(horizontal, x: CGFloat(gestureAnchor!) * document.frame.width - horizontal.contentView.bounds.width / 2)
        zoomGrid = grid
        lastZoomFrame = ProcessInfo.processInfo.systemUptime - 1.0 / 60
        if #available(macOS 14.0, *), window?.isVisible == true {
            let target = TimelineDisplayLinkTarget { [weak self] in self?.displayZoomFrame() }
            let link = displayLink(target: target, selector: #selector(TimelineDisplayLinkTarget.tick))
            link.add(to: .main, forMode: .common)
            cancelDisplayLink = { link.invalidate() }
        } else {
            // macOS 13 and non-displayed test hosts retain the same scheduler.
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.displayZoomFrame() }
            timer.tolerance = 0
            zoomTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        advanceZoom(grid)
    }
    private func displayZoomFrame() {
        guard let grid = zoomGrid, window != nil else { stopZoomUpdates(); return }
        advanceZoom(grid)
    }
    private func stopZoomUpdates() {
        if zoomRunning { UserDefaults.standard.set(zoom, forKey: "jaras.timelineZoom") }
        cancelDisplayLink?()
        cancelDisplayLink = nil
        zoomGrid = nil
        zoomTimer?.invalidate()
        zoomTimer = nil
        pendingZoom = nil
        gestureAnchor = nil
        lastZoomFrame = 0; zoomDirection = 0
    }
    private func advanceZoom(_ grid: GridNativeScrollView) {
        guard let target = pendingZoom else { stopZoomUpdates(); return }
        // Scale in logarithmic space; position keeps the same green-cursor anchor.
        guard target != zoom else {
            if ProcessInfo.processInfo.systemUptime - lastZoomInput > 0.08 { stopZoomUpdates() }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = min(1.0/30,max(1.0/240,now-lastZoomFrame)); lastZoomFrame = now
        let distance = log(target/zoom)
        let next = abs(distance) < 0.0015 ? target : zoom * exp(distance * (1-exp(-elapsed/0.022)))
        let fraction = gestureAnchor ?? min(1, max(0, position))
        let width = documentUnitWidth * next
        let screenX = grid.contentView.frame.width / 2
        let offset = min(max(0, CGFloat(fraction) * width - screenX), max(0, width - grid.contentView.frame.width))
        grid.zoomAnchor = (fraction, screenX, width)
        zoom = next
        changeZoom?(next, offset)
    }

}
private final class TimelineDisplayLinkTarget: NSObject {
    let callback: () -> Void
    init(_ callback: @escaping () -> Void) { self.callback = callback }
    @objc func tick() { callback() }
}
/// Limited to the numbered ruler. Clip clicks never enter this view.
struct TimelineRulerInput: NSViewRepresentable {
    var extend: () -> Void = {}
    var selectTime: (Double, Double) -> Void = { _, _ in }
    let seek: (Double, Bool) -> Void
    func makeNSView(context: Context) -> TimelineRulerView { TimelineRulerView() }
    func updateNSView(_ view: TimelineRulerView, context: Context) { view.seek = seek; view.extend = extend; view.selectTime = selectTime }
}
final class TimelineRulerView: NSView, NativeTimelineInputObserver {
    var seek: ((Double, Bool) -> Void)?
    var selectTime: ((Double, Double) -> Void)?
    private var selectionStart: Double?
    private var selectingTime = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var extend: (() -> Void)?
    private var startX: CGFloat?
    private var previousX: CGFloat = 0
    private var dragging = false
    private var secondaryClick = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { NativeTimelineInputGate.shared.add(self) }
    }
    func timelineInputGateChanged(blocked: Bool) {
        if blocked { startX = nil; dragging = false; secondaryClick = false; selectionStart = nil; selectingTime = false }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        guard !NativeTimelineInputGate.shared.isBlocked(window) else { return }
        startX = event.locationInWindow.x
        previousX = event.locationInWindow.x
        dragging = false
        secondaryClick = event.modifierFlags.contains(.control)
    }
    override func mouseDragged(with event: NSEvent) {
        guard !NativeTimelineInputGate.shared.isBlocked(window), let startX, !secondaryClick else { return }
        if !dragging && abs(event.locationInWindow.x - startX) < 3 { return }
        dragging = true
        NSCursor.closedHand.set()
        let delta = event.locationInWindow.x - previousX
        previousX = event.locationInWindow.x
        var parent = superview
        while let view = parent {
            if let scroll = view as? NSScrollView, let document = scroll.documentView {
                let clip = scroll.contentView
                let target = max(0, clip.bounds.minX - delta)
                if delta < 0 && target + clip.bounds.width > document.frame.width - 300 { extend?() }
                clip.scroll(to: NSPoint(x: min(target, max(0, document.frame.width - clip.bounds.width)), y: clip.bounds.minY))
                scroll.reflectScrolledClipView(clip)
                break
            }
            parent = view.superview
        }
    }
    override func mouseUp(with event: NSEvent) {
        guard !NativeTimelineInputGate.shared.isBlocked(window), startX != nil else { return }
        if !dragging { move(event, secondary: secondaryClick) }
        startX = nil
        dragging = false
        NSCursor.openHand.set()
    }
    override func rightMouseDown(with event: NSEvent) {
        guard !NativeTimelineInputGate.shared.isBlocked(window) else { return }
        selectionStart = fraction(event)
        startX = event.locationInWindow.x
        selectingTime = false
    }
    override func rightMouseDragged(with event: NSEvent) {
        guard !NativeTimelineInputGate.shared.isBlocked(window), let selectionStart, let startX else { return }
        guard selectingTime || abs(event.locationInWindow.x - startX) >= 3 else { return }
        selectingTime = true
        selectTime?(selectionStart, fraction(event))
    }
    override func rightMouseUp(with event: NSEvent) {
        guard !NativeTimelineInputGate.shared.isBlocked(window), let selectionStart else { return }
        if selectingTime { selectTime?(selectionStart, fraction(event)) }
        else { move(event, secondary: true) }
        self.selectionStart = nil; startX = nil; selectingTime = false
    }
    private func fraction(_ event: NSEvent) -> Double {
        Double(min(1, max(0, convert(event.locationInWindow, from: nil).x / max(1, bounds.width))))
    }
    private func move(_ event: NSEvent, secondary: Bool) {
        let x = convert(event.locationInWindow, from: nil).x
        seek?(Double(min(1, max(0, x / max(1, bounds.width)))), secondary)
    }
}
#endif

#if os(macOS)
/// The same maximum speed at 60 Hz or 120 Hz; small movements stay unchanged.
struct HorizontalScrollLimiter {
    private var lastTimestamp: TimeInterval?
    mutating func limit(_ distance: CGFloat, timestamp: TimeInterval, begins: Bool) -> CGFloat {
        let elapsed: TimeInterval
        if begins || lastTimestamp == nil {
            elapsed = 1.0 / 60
        } else {
            elapsed = min(1.0 / 30, max(0, timestamp - lastTimestamp!))
        }
        lastTimestamp = timestamp
        let maximum = CGFloat(elapsed * 4200)
        return min(maximum, max(-maximum, distance))
    }
}
#endif
