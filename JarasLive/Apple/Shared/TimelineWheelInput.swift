#if os(macOS)
import SwiftUI
import AppKit
import QuartzCore

/// Command/Control + wheel changes row height even when the pointer is over the mixer.
struct TimelineMixerHeightWheelInput: NSViewRepresentable {
    let change: (Double) -> Void
    func makeNSView(context: Context) -> TimelineMixerHeightWheelView { TimelineMixerHeightWheelView() }
    func updateNSView(_ view: TimelineMixerHeightWheelView, context: Context) { view.change = change }
}
final class TimelineMixerHeightWheelView: NSView {
    var change: ((Double) -> Void)?
    private var monitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    @discardableResult func handle(_ event: NSEvent) -> Bool {
        guard event.window === window, window?.attachedSheet == nil,
              !NativeTimelineInputGate.shared.isBlocked(window),
              !event.modifierFlags.intersection([.command, .control]).isEmpty,
              event.momentumPhase.isEmpty, event.scrollingDeltaY != 0,
              !isHiddenOrHasHiddenAncestor,
              visibleRect.contains(convert(event.locationInWindow, from: nil)) else { return false }
        let amount = Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? TimelineTrackHeightLimits.preciseSensitivity : TimelineTrackHeightLimits.wheelSensitivity)
        let factor = exp(min(0.08, max(-0.08, amount)))
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { change?(factor) }
        return true
    }
}

/// Observes only wheel events over this timeline; clicks and playhead drags pass through.
struct TimelineWheelInput: NSViewRepresentable {
    @Binding var zoom: Double
    let position: Double
    let extend: () -> Void
    let horizontalOffsetChanged: (CGFloat) -> Void
    let verticalOffsetChanged: (CGFloat) -> Void
    let focusRequest: UUID
    let focusX: CGFloat?
    var cursorX: CGFloat? = nil
    var modelUnitWidth: Double? = nil
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
        view.cursorX = cursorX
        view.modelUnitWidth = modelUnitWidth
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
/// Small motions keep a fine scale. A sustained, fast swipe progressively uses
/// more range, independently of the trackpad's event frequency.
struct TimelineZoomResponse {
    private var lastTime: Double?
    private var direction = 0.0
    private var velocity = 0.0
    private var travel = 0.0

    mutating func reset() { self = Self() }
    mutating func change(delta: Double, timestamp: Double, begins: Bool) -> Double {
        guard delta != 0 else {
            if begins { reset(); lastTime = timestamp }
            return 0
        }
        let sign = delta > 0 ? 1.0 : -1.0
        let fresh = begins || lastTime == nil || timestamp - (lastTime ?? timestamp) > 0.14 || (direction != 0 && direction != sign)
        if fresh { velocity = 0; travel = 0 }
        let elapsed = fresh ? 1.0 / 60 : min(0.05, max(1.0 / 240, timestamp - (lastTime ?? timestamp)))
        let speed = abs(delta) / elapsed
        velocity = fresh ? speed : velocity + (speed - velocity) * (1 - exp(-elapsed / 0.016))
        travel += abs(delta)
        lastTime = timestamp; direction = sign
        func ease(_ value: Double) -> Double {
            let bounded = min(1, max(0, value))
            return bounded * bounded * (3 - 2 * bounded)
        }
        // Gentle gestures need more room for small corrections. A genuinely
        // fast swipe still reaches the full zoom range in one movement.
        let fast = ease((min(velocity, speed) - 200) / 1000)
        let sustained = ease((travel - 2) / 18)
        let sensitivity = TimelineZoomLimits.preciseSensitivity + (TimelineZoomLimits.maximumPreciseSensitivity - TimelineZoomLimits.preciseSensitivity) * fast * sustained
        // Apply even the first fractional delta. Accumulating a minimum step
        // delayed gentle gestures by several input events and made reversals
        // feel stuck. Frame coalescing below already bounds the layout rate.
        return delta * sensitivity
    }
}

final class TimelineWheelView: NSView, NativeTimelineInputObserver {
    var interactionBlocked = false { didSet { if interactionBlocked && !oldValue { stopZoomUpdates(); stopScrollCoast() } } }
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
    var cursorX: CGFloat?
    var modelUnitWidth: Double?
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
    private var lastZoomAmount = 0.0
    private var coastRemaining = 0.0
    private var coastStarted = false
    private var coastFrame = 0.0
    private var nativeMomentumSeen = false
    private var physicalWheelZoom = false
    private var physicalZoomFrame = 0.0
    private var zoomResponse = TimelineZoomResponse()
    private var documentUnitWidth = 1.0
    private var lastFocusRequest: UUID?
    func focus(request: UUID, x: CGFloat?) {
        guard lastFocusRequest != request else { return }
        lastFocusRequest = request
        guard let x else { return }
        // The native viewport already has its geometry. Revealing a cursor must
        // not synchronously lay out the whole window or wait for another turn.
        if let horizontal = scrollViews.first {
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
            DispatchQueue.main.async { [weak self, weak horizontal] in
                guard let self, let horizontal, self.lastFocusRequest == request else { return }
                let bucket = floor(horizontal.contentView.bounds.minX / 512) * 512
                self.lastHorizontalBucket = bucket
                self.horizontalOffsetChanged?(bucket)
            }
        }
    }
    private var monitor: Any?
    private var trackpadHorizontal: Bool?
    private var horizontalLimiter = HorizontalScrollLimiter()
    private var scrollCoastTimer: Timer?
    private weak var scrollCoastView: NSScrollView?
    private var scrollCoastRemaining: CGFloat = 0
    private var scrollCoastFrame = 0.0
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopZoomUpdates(); stopScrollCoast() }
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
        if blocked { stopZoomUpdates(); stopScrollCoast(); trackpadHorizontal = nil }
    }
    @discardableResult func handleWheelEvent(_ event: NSEvent, pressedMouseButtons: Int = NSEvent.pressedMouseButtons) -> Bool {
        guard !interactionBlocked, !NativeTimelineInputGate.shared.isBlocked(window),
              event.window === window, window != nil, window?.attachedSheet == nil,
              visibleRect.contains(convert(event.locationInWindow, from: nil)) else { return false }
        return handle(event, pressedMouseButtons: pressedMouseButtons)
    }
    deinit { cancelDisplayLink?(); zoomTimer?.invalidate(); scrollCoastTimer?.invalidate(); if let horizontalObserver { NotificationCenter.default.removeObserver(horizontalObserver) }; if let monitor { NSEvent.removeMonitor(monitor) }; if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) } }
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
    private func stopScrollCoast() {
        scrollCoastTimer?.invalidate(); scrollCoastTimer = nil
        scrollCoastView = nil; scrollCoastRemaining = 0
    }
    private func startScrollCoast(_ view: NSScrollView, distance: CGFloat) {
        guard abs(distance) > 0.05 else { return }
        scrollCoastView = view
        scrollCoastRemaining = min(20, max(-20, distance * 0.22))
        // The physical wheel's step is already visible. Only its release
        // tail is scheduled; another event cancels it before applying a step.
        scrollCoastFrame = ProcessInfo.processInfo.systemUptime + 0.025
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.advanceScrollCoast() }
        timer.tolerance = 0
        scrollCoastTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func advanceScrollCoast() {
        guard let view = scrollCoastView, window != nil, view.window === window, window?.attachedSheet == nil,
              !interactionBlocked, !NativeTimelineInputGate.shared.isBlocked(window),
              abs(scrollCoastRemaining) >= 0.05 else { stopScrollCoast(); return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now > scrollCoastFrame else { return }
        let elapsed = min(0.05, now - scrollCoastFrame)
        scrollCoastFrame = now
        let portion = scrollCoastRemaining * CGFloat(1 - exp(-elapsed / 0.065))
        scrollCoastRemaining -= portion
        let old = view.contentView.bounds.minX
        scroll(view, x: old - portion)
        if view.contentView.bounds.minX == old { stopScrollCoast() }
    }
    private func handle(_ event: NSEvent, pressedMouseButtons: Int) -> Bool {
        let views = scrollViews
        guard let horizontal = views.first else { return false }
        let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
        let movement = delta * (event.hasPreciseScrollingDeltas ? 1 : 18)
        let heldLeftWheel = pressedMouseButtons & 1 != 0 && !event.hasPreciseScrollingDeltas &&
            event.momentumPhase.isEmpty &&
            event.modifierFlags.intersection([.command, .control, .shift, .option]).isEmpty
        stopScrollCoast()
        if !event.modifierFlags.intersection([.command, .control]).isEmpty {
            stopZoomUpdates()
            if event.momentumPhase.isEmpty, event.scrollingDeltaY != 0 {
                let amount = Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? TimelineTrackHeightLimits.preciseSensitivity : TimelineTrackHeightLimits.wheelSensitivity)
                changeTrackHeight?(exp(min(0.08, max(-0.08, amount))))
            }
        } else if event.modifierFlags.contains(.shift) || heldLeftWheel {
            stopZoomUpdates()
            if heldLeftWheel, delta != 0, let window {
                // A delayed zoom anchor must not recenter a viewport now owned
                // by this pan; a ruler/item press must not activate on release.
                (horizontal as? GridNativeScrollView)?.zoomAnchor = nil
                NativeTimelineInputGate.shared.cancelPendingClicks(for: window)
            }
            let limited = horizontalLimiter.limit(movement, timestamp: event.timestamp, begins: event.phase.contains(.began))
            let origin = horizontal.contentView.bounds.minX
            let target = origin - limited
            if let document = horizontal.documentView, target + horizontal.contentView.bounds.width > document.frame.width - 160 { extend?() }
            scroll(horizontal, x: target)
            if !event.hasPreciseScrollingDeltas { startScrollCoast(horizontal, distance: origin - horizontal.contentView.bounds.minX) }
        } else if event.hasPreciseScrollingDeltas && (!event.phase.isEmpty || !event.momentumPhase.isEmpty) {
            // Use the trackpad's own momentum deltas, with a time-based speed
            // ceiling. Do not queue excess distance or run an idle animation timer.
            // AppKit can begin a new gesture with no movement. Forget the
            // previous axis now and choose again on its first nonzero delta.
            // Keep that choice through .ended for the native momentum tail.
            if event.phase.contains(.began) { trackpadHorizontal = nil }
            if trackpadHorizontal == nil {
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
        // Physical steps start immediately and interpolate toward an exact target.
        // Trackpad input retains its native momentum.
        if !event.hasPreciseScrollingDeltas && zoomRunning && !physicalWheelZoom { stopZoomUpdates() }
        if event.phase.contains(.began), event.momentumPhase.isEmpty, zoomRunning { stopZoomUpdates() }
        physicalWheelZoom = !event.hasPreciseScrollingDeltas
        if event.momentumPhase.contains(.ended) {
            if let zoomGrid { advanceZoom(zoomGrid) }
            stopZoomUpdates()
            return
        }
        if !event.momentumPhase.isEmpty {
            // The system has already calculated a decelerating trackpad tail.
            // Do not add a second synthetic tail on top of it.
            nativeMomentumSeen = true
            coastRemaining = 0
            coastStarted = true
        }
        let amount = event.hasPreciseScrollingDeltas
            ? zoomResponse.change(delta: Double(delta), timestamp: event.timestamp, begins: event.phase.contains(.began))
            : Double(delta) * TimelineZoomLimits.wheelSensitivity
        guard delta != 0, let grid = horizontal as? GridNativeScrollView,
              let document = horizontal.documentView else { return }
        // Input remains active at a zoom limit too. The release timer must not
        // start a coast merely because this event could not change the scale.
        lastZoomInput = ProcessInfo.processInfo.systemUptime
        if event.momentumPhase.isEmpty {
            coastRemaining = 0
            coastStarted = false
        }
        if !zoomRunning {
            // Native geometry may lag a newer scale, especially after a fast
            // reversal. Derive the document target from the model, not that
            // intermediate frame; otherwise the anchor can never settle.
            documentUnitWidth = modelUnitWidth ?? ((grid.zoomAnchor?.width ?? document.frame.width) / zoom)
            // The musical position is independent of the rendered scale.
            // cursorX can still belong to the previous layout when a fast new
            // gesture arrives after the native document has changed width.
            let fraction = min(1, max(0, position))
            let cursor = CGFloat(fraction) * document.frame.width
            gestureAnchor = fraction
            scroll(horizontal, x: cursor - horizontal.contentView.bounds.width / 2)
            let bucket = floor(horizontal.contentView.bounds.minX / 512) * 512
            lastHorizontalBucket = bucket
            horizontalOffsetChanged?(bucket)
        }
        // A reversal discards the old physical-wheel destination immediately.
        if physicalWheelZoom && lastZoomAmount * amount < 0 { pendingZoom = zoom }
        if !zoomRunning { physicalZoomFrame = ProcessInfo.processInfo.systemUptime - 1.0 / 60 }
        let base = pendingZoom ?? zoom
        let next = min(TimelineZoomLimits.maximum, max(TimelineZoomLimits.minimum, base * exp(amount)))
        guard next != base else { if !zoomRunning { gestureAnchor = nil }; return }
        pendingZoom = next
        lastZoomAmount = amount
        // Apply the first input immediately. Merge a burst into the next display
        // frame without interpolating toward an old target after the gesture.
        if zoomRunning {
            if physicalWheelZoom { advanceZoom(grid) }
            return
        }
        zoomGrid = grid
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
        guard let grid = zoomGrid, window != nil, window?.attachedSheet == nil else { stopZoomUpdates(); return }
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
        zoomResponse.reset()
        lastZoomAmount = 0
        coastRemaining = 0
        coastStarted = false
        coastFrame = 0
        nativeMomentumSeen = false
        physicalWheelZoom = false
    }
    private func advanceZoom(_ grid: GridNativeScrollView) {
        guard let target = pendingZoom else { stopZoomUpdates(); return }
        // Finger movement takes the full value in the next display frame.
        // After release, a small ease-out is used only if no native trackpad
        // momentum arrived. New input cancels the tail immediately.
        if target == zoom {
            if physicalWheelZoom { stopZoomUpdates(); return }
            let now = ProcessInfo.processInfo.systemUptime
            let idle = now - lastZoomInput
            if idle < (physicalWheelZoom ? 0.022 : 0.045) { return }
            if !coastStarted && !nativeMomentumSeen {
                let limit = physicalWheelZoom ? 0.03 : 0.07
                let fraction = physicalWheelZoom ? 0.22 : 0.50
                coastRemaining = copysign(min(limit, abs(lastZoomAmount) * fraction), lastZoomAmount)
                coastStarted = true
                coastFrame = now
            }
            if abs(coastRemaining) < 0.00025 {
                if idle > (physicalWheelZoom ? 0.04 : 0.08) { stopZoomUpdates() }
                return
            }
            let elapsed = min(0.05, max(1.0 / 240, now - coastFrame))
            coastFrame = now
            let portion = coastRemaining * (1 - exp(-elapsed / (physicalWheelZoom ? 0.065 : 0.045)))
            coastRemaining -= portion
            let eased = min(TimelineZoomLimits.maximum, max(TimelineZoomLimits.minimum, zoom * exp(portion)))
            guard eased != zoom else { stopZoomUpdates(); return }
            pendingZoom = eased
        }
        let destination = pendingZoom ?? target
        let next: Double
        if physicalWheelZoom {
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = min(0.05, max(0, now - physicalZoomFrame)); physicalZoomFrame = now
            let distance = log(destination / zoom)
            next = abs(distance) < 0.0003 ? destination : zoom * exp(distance * (1 - exp(-elapsed / 0.055)))
        } else { next = destination }
        guard next != zoom else { return }
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
    var markerCursor: (NSEvent) -> Bool = { _ in false }
    var extend: () -> Void = {}
    var selectTime: (Double, Double) -> Void = { _, _ in }
    var selectedTime: () -> (Double, Double)? = { nil }
    var resizeTime: (Double, Bool) -> Void = { _, _ in }
    let seek: (Double, Bool, Bool) -> Void
    func makeNSView(context: Context) -> TimelineRulerView { TimelineRulerView() }
    func updateNSView(_ view: TimelineRulerView, context: Context) { view.seek = seek; view.extend = extend; view.selectTime = selectTime; view.selectedTime = selectedTime; view.resizeTime = resizeTime; view.markerCursor = markerCursor }
}
final class TimelineRulerView: NSView, NativeTimelineInputObserver {
    var markerCursor: (NSEvent) -> Bool = { _ in false }
    var seek: ((Double, Bool, Bool) -> Void)?
    var selectTime: ((Double, Double) -> Void)?
    var selectedTime: (() -> (Double, Double)?)?
    var resizeTime: ((Double, Bool) -> Void)?
    private var selectionEdge: Bool?
    private var hoverTracking: NSTrackingArea?
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
        if blocked { startX = nil; dragging = false; secondaryClick = false; selectionStart = nil; selectingTime = false; selectionEdge = nil }
    }
    func timelinePendingClickCancelled() {
        guard !dragging, selectionStart == nil else { return }
        startX = nil; secondaryClick = false; selectionEdge = nil
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        hoverTracking = tracking; addTrackingArea(tracking)
    }
    override func cursorUpdate(with event: NSEvent) { updatePointer(event) }
    override func mouseEntered(with event: NSEvent) { updatePointer(event) }
    override func mouseMoved(with event: NSEvent) { updatePointer(event) }
    private func updatePointer(_ event: NSEvent) {
        guard !NativeTimelineInputGate.shared.isBlocked(window) else { return }
        if markerCursor(event) || selectionEdge != nil || areaEdge(event) != nil { NSCursor.resizeLeftRight.set() }
        else { (dragging ? NSCursor.closedHand : NSCursor.openHand).set() }
    }
    private func areaEdge(_ event: NSEvent) -> Bool? {
        guard let range = selectedTime?(), bounds.width > 0 else { return nil }
        let x = convert(event.locationInWindow, from: nil).x
        let left = abs(x - range.0 * bounds.width), right = abs(x - range.1 * bounds.width)
        guard min(left, right) <= 8 else { return nil }
        return left <= right
    }
    override func mouseDown(with event: NSEvent) {
        guard !NativeTimelineInputGate.shared.isBlocked(window) else { return }
        startX = event.locationInWindow.x
        previousX = event.locationInWindow.x
        dragging = false
        secondaryClick = event.modifierFlags.contains(.control)
        selectionEdge = areaEdge(event)
    }
    override func mouseDragged(with event: NSEvent) {
        guard !NativeTimelineInputGate.shared.isBlocked(window), let startX, !secondaryClick else { return }
        if !dragging && abs(event.locationInWindow.x - startX) < 3 { return }
        dragging = true
        if let selectionEdge {
            resizeTime?(fraction(event), selectionEdge)
            NSCursor.resizeLeftRight.set()
            return
        }
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
        if let selectionEdge {
            if dragging { resizeTime?(fraction(event), selectionEdge) }
        } else if !dragging { move(event, secondary: secondaryClick) }
        selectionEdge = nil
        startX = nil
        dragging = false
        NSCursor.openHand.set()
    }
    override func rightMouseDown(with event: NSEvent) {
        guard !NativeTimelineInputGate.shared.isBlocked(window) else { return }
        selectionStart = fraction(event)
        selectionEdge = areaEdge(event)
        startX = event.locationInWindow.x
        selectingTime = false
    }
    override func rightMouseDragged(with event: NSEvent) {
        guard !NativeTimelineInputGate.shared.isBlocked(window), let selectionStart, let startX else { return }
        guard selectingTime || abs(event.locationInWindow.x - startX) >= 3 else { return }
        selectingTime = true
        if let selectionEdge { resizeTime?(fraction(event), selectionEdge) }
        else { selectTime?(selectionStart, fraction(event)) }
    }
    override func rightMouseUp(with event: NSEvent) {
        guard !NativeTimelineInputGate.shared.isBlocked(window), let selectionStart else { return }
        if let selectionEdge {
            if selectingTime { resizeTime?(fraction(event), selectionEdge) }
        } else if selectingTime { selectTime?(selectionStart, fraction(event)) }
        else { move(event, secondary: true) }
        self.selectionStart = nil; startX = nil; selectingTime = false; selectionEdge = nil
    }
    private func fraction(_ event: NSEvent) -> Double {
        Double(min(1, max(0, convert(event.locationInWindow, from: nil).x / max(1, bounds.width))))
    }
    private func move(_ event: NSEvent, secondary: Bool) {
        let x = convert(event.locationInWindow, from: nil).x
        seek?(Double(min(1, max(0, x / max(1, bounds.width)))), secondary, event.modifierFlags.contains(.shift))
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
