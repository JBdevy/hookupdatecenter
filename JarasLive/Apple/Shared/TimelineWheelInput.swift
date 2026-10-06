#if os(macOS)
import SwiftUI
import AppKit
import QuartzCore

/// Time-weighted velocity changes gain, never the sign or duration of travel.
/// Deltas already include native acceleration, so the additional gain is modest.
struct TimelineInputVelocityResponse {
    private var previousTime: Double?
    private var speed = 0.0
    private var direction = 0.0
    mutating func reset() { previousTime = nil; speed = 0; direction = 0 }
    mutating func change(amount: Double, timestamp: Double, begins: Bool, precise: Bool) -> Double {
        guard amount.isFinite, timestamp.isFinite else { reset(); return amount.isFinite ? amount : 0 }
        if begins { reset() }
        let previous = previousTime
        if previous == nil || timestamp > previous! { previousTime = timestamp }
        guard amount != 0 else { return 0 }
        let sign = amount > 0 ? 1.0 : -1.0
        let reversed = direction != 0 && sign != direction
        direction = sign
        guard !begins, !reversed, let previous, timestamp > previous,
              timestamp - previous < 0.25 else { speed = 0; return amount }
        let elapsed = timestamp - previous
        let instantaneous = abs(amount) / elapsed
        let decay = exp(-elapsed / 0.07)
        // Mean filtered speed over the interval is less sensitive to how one
        // movement is divided into 60/120/240-Hz native events.
        let mean = instantaneous + (speed - instantaneous) * (0.07 / elapsed) * (1 - decay)
        speed = instantaneous + (speed - instantaneous) * decay
        // A small correction after a swipe must not inherit its old speed.
        let effective = min(instantaneous, max(0, mean))
        let weight = min(1, max(0, (effective - 0.35) / (2.5 - 0.35)))
        return amount * (1 + weight * (precise ? 0.12 : 0.4))
    }
}

/// Apply signed wheel travel to an unrounded target; presentation quantizes it.
enum TimelineTrackHeightInput {
    static func height(from height: CGFloat, factor: Double) -> CGFloat {
        guard factor.isFinite, factor > 0 else { return height }
        return min(TimelineTrackHeightLimits.maximum, max(TimelineTrackHeightLimits.minimum, height + CGFloat(log(factor)) * TimelineTrackHeightLimits.defaultHeight))
    }
}

/// A discrete wheel gets a brief finish after its immediate first movement.
/// The deadline is fixed in time, so a late frame completes the movement rather
/// than replaying missed animation steps.
private struct TimelineTrackHeightWheelTransition {
    let from: CGFloat
    let to: CGFloat
    let began: Double
    static let duration = 0.065
    func value(at time: Double) -> CGFloat {
        let progress = min(1, max(0, (time - began) / Self.duration))
        let eased = 1 - (1 - progress) * (1 - progress)
        return from + (to - from) * CGFloat(0.6 + 0.4 * eased)
    }
}

/// Consume every input delta and publish a shared integer geometry at most once
/// per display frame. Precise devices remain direct; only discrete wheel input
/// gets a short transition, without independent mixer/item animations.
final class TimelineTrackHeightMotion {
    private let layoutProfile = TimelineLayoutDiagnostics.make("height-motion")
    private var requested: CGFloat?
    private var applied: CGFloat?
    private var apply: ((CGFloat) -> Void)?
    private var lastInput = 0.0
    private var wheelTransition: TimelineTrackHeightWheelTransition?
    private var wheelDirection = 0.0
    private var timer: Timer?
    private var cancelDisplayLink: (() -> Void)?
    private weak var window: NSWindow?
    private var running: Bool { timer != nil || cancelDisplayLink != nil }

    func change(factor: Double, current: CGFloat, smoothWheel: Bool = false, apply: @escaping (CGFloat) -> Void) {
        guard factor.isFinite, factor > 0, current.isFinite else { return }
        // Retain sub-point travel through idle, but honor an external height
        // change (new project, keyboard command, or another control).
        if !running, applied != current { requested = current; applied = current; wheelTransition = nil; wheelDirection = 0 }
        layoutProfile?.event("height-request", view: NSApp?.currentEvent?.window?.contentView ?? window?.contentView, value: factor)
        self.apply = apply
        let now = ProcessInfo.processInfo.systemUptime
        let direction = factor > 1 ? 1.0 : factor < 1 ? -1.0 : 0.0
        if wheelTransition != nil, !smoothWheel || (direction != 0 && wheelDirection != 0 && direction != wheelDirection) {
            // A reverse must immediately follow the pointer, not finish the
            // previous direction's unseen remainder. Switching to precise
            // input also discards that short tail. The callback's current
            // height may still belong to the preceding SwiftUI frame.
            requested = applied ?? current
        }
        if direction != 0 { wheelDirection = smoothWheel ? direction : 0 }
        requested = TimelineTrackHeightInput.height(from: requested ?? current, factor: factor)
        let displayed = applied ?? current
        if smoothWheel, let requested, abs(requested - displayed) >= 2 {
            wheelTransition = TimelineTrackHeightWheelTransition(from: displayed, to: requested, began: now)
        } else {
            // Fine corrections and trackpad input retain the direct path.
            wheelTransition = nil
        }
        lastInput = now
        guard !running else { return }
        // A wheel can target the project while a teleprompter or FX window
        // remains key. Follow the input's window for display and modal checks.
        window = NSApp?.currentEvent?.window ?? NSApp?.keyWindow
        applied = current
        commit()
        // Fractional input accumulates without scheduling idle layout work.
        guard requested?.rounded() != current else { return }
        if #available(macOS 14.0, *), let host = window?.contentView, window?.isVisible == true {
            let target = TimelineDisplayLinkTarget { [weak self] in self?.tick() }
            let link = host.displayLink(target: target, selector: #selector(TimelineDisplayLinkTarget.tick))
            link.add(to: .main, forMode: .common)
            cancelDisplayLink = { link.invalidate() }
        } else {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    private func commit() {
        guard let requested else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let presented = wheelTransition?.value(at: now) ?? requested
        let height = min(TimelineTrackHeightLimits.maximum, max(TimelineTrackHeightLimits.minimum, presented.rounded()))
        if height == requested.rounded() { wheelTransition = nil }
        guard height != applied else { return }
        applied = height
        layoutProfile?.event("height-publish", view: window?.contentView, value: Double(height))
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { apply?(height) }
    }
    private func tick() {
        layoutProfile?.event("height-tick", view: window?.contentView)
        if let window, window.attachedSheet != nil || NativeTimelineInputGate.shared.isBlocked(window) {
            cancel(); return
        }
        commit()
        if ProcessInfo.processInfo.systemUptime - lastInput > 0.08 { stop(preservingRemainder: true) }
    }
    private func stop(preservingRemainder: Bool) {
        cancelDisplayLink?(); cancelDisplayLink = nil
        timer?.invalidate(); timer = nil
        apply = nil
        wheelTransition = nil
        if !preservingRemainder { requested = nil; applied = nil; wheelDirection = 0 }
    }
    func cancel() { stop(preservingRemainder: false) }
    deinit { timer?.invalidate(); cancelDisplayLink?() }
}

struct TimelineTrackHeightResponse {
    private var velocity = TimelineInputVelocityResponse()
    mutating func reset() { velocity.reset() }
    mutating func factor(delta: Double, timestamp: Double, begins: Bool, precise: Bool) -> Double {
        let sensitivity = precise ? TimelineTrackHeightLimits.preciseSensitivity : TimelineTrackHeightLimits.wheelSensitivity
        let amount = velocity.change(amount: delta * sensitivity, timestamp: timestamp, begins: begins, precise: precise)
        return exp(min(TimelineTrackHeightLimits.maximumWheelStep, max(-TimelineTrackHeightLimits.maximumWheelStep, amount)))
    }
}

/// Command/Control + wheel changes row height even when the pointer is over the mixer.
struct TimelineMixerHeightWheelInput: NSViewRepresentable {
    let change: (Double, Bool) -> Void
    func makeNSView(context: Context) -> TimelineMixerHeightWheelView { TimelineMixerHeightWheelView() }
    func updateNSView(_ view: TimelineMixerHeightWheelView, context: Context) { view.change = change }
}
final class TimelineMixerHeightWheelView: NSView, NativeTimelineInputObserver {
    private let layoutProfile = TimelineLayoutDiagnostics.make("mixer-height-input")
    var change: ((Double, Bool) -> Void)?
    private var response = TimelineTrackHeightResponse()
    private var monitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        response.reset()
        guard window != nil else { return }
        NativeTimelineInputGate.shared.add(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    func timelineInputGateChanged(blocked: Bool) { if blocked { response.reset() } }
    @discardableResult func handle(_ event: NSEvent) -> Bool {
        if event.window === window, event.phase.contains(.began) { response.reset() }
        guard event.window === window, window?.attachedSheet == nil,
              !NativeTimelineInputGate.shared.isBlocked(window),
              !event.modifierFlags.intersection([.command, .control]).isEmpty,
              event.momentumPhase.isEmpty, event.scrollingDeltaY != 0,
              !isHiddenOrHasHiddenAncestor,
              visibleRect.contains(convert(event.locationInWindow, from: nil)) else { return false }
        layoutProfile?.event("input-received", view: self, input: event)
        let factor = response.factor(delta: Double(event.scrollingDeltaY), timestamp: event.timestamp,
            begins: event.phase.contains(.began), precise: event.hasPreciseScrollingDeltas)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { change?(factor, !event.hasPreciseScrollingDeltas) }
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
    var changeTrackHeight: (Double, Bool) -> Void = { _, _ in }
    var livePosition: (() -> Double)? = nil
    func makeNSView(context: Context) -> TimelineWheelView { TimelineWheelView() }
    func updateNSView(_ view: TimelineWheelView, context: Context) {
        view.horizontalOffsetChanged = horizontalOffsetChanged
        view.interactionBlocked = interactionBlocked
        view.changeTrackHeight = { factor, smoothWheel in
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { changeTrackHeight(factor, smoothWheel) }
        }
        view.observeHorizontalScroll()
        view.verticalOffsetChanged = verticalOffsetChanged
        view.observeVerticalScroll()
        view.extend = extend
        view.acceptRenderedZoom(zoom)
        view.position = position
        view.livePosition = livePosition
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
/// Zoom remains continuous; velocity only scales each native signed delta.
struct TimelineZoomResponse {
    private var velocity = TimelineInputVelocityResponse()
    mutating func reset() { velocity.reset() }
    mutating func change(delta: Double, timestamp: Double, begins: Bool, precise: Bool = true) -> Double {
        velocity.change(amount: delta * (precise ? TimelineZoomLimits.preciseSensitivity : TimelineZoomLimits.wheelSensitivity),
            timestamp: timestamp, begins: begins, precise: precise)
    }
}

/// Finish a mouse notch in a fixed, short interval using the same logarithmic
/// scale as input. The first frame responds immediately; late frames go straight
/// to the target instead of extending a deceleration tail.
private struct TimelineWheelZoomTransition {
    let from: Double
    let to: Double
    let began: Double
    static let duration = 0.090
    func value(at time: Double) -> Double {
        let progress = min(1, max(0, (time - began) / Self.duration))
        guard progress < 1 else { return to }
        let eased = 1 - (1 - progress) * (1 - progress)
        return exp(log(from) + (log(to) - log(from)) * (0.6 + 0.4 * eased))
    }
}

final class TimelineWheelView: NSView, NativeTimelineInputObserver {
    private let layoutProfile = TimelineLayoutDiagnostics.make("timeline-input")
    var interactionBlocked = false { didSet { if interactionBlocked && !oldValue { stopZoomUpdates() } } }
    var horizontalOffsetChanged: ((CGFloat) -> Void)?
    private weak var observedHorizontal: NSClipView?
    private var horizontalObserver: NSObjectProtocol?
    private var lastHorizontalBucket: CGFloat?
    @discardableResult private func publishHorizontalOffset(_ offset: CGFloat) -> Bool {
        let bucket = floor(max(0, offset) / 512) * 512
        guard lastHorizontalBucket != bucket else { return false }
        lastHorizontalBucket = bucket
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { horizontalOffsetChanged?(bucket) }
        return true
    }
    func observeHorizontalScroll() {
        defer { schedulePendingFocus() }
        guard let clip = scrollViews.first?.contentView, observedHorizontal !== clip else { return }
        if let horizontalObserver { NotificationCenter.default.removeObserver(horizontalObserver) }
        observedHorizontal = clip
        lastHorizontalBucket = nil
        (clip.superview as? GridNativeScrollView)?.prepareHorizontalScroll = { [weak self] offset in
            self?.publishHorizontalOffset(offset) ?? false
        }
        clip.postsBoundsChangedNotifications = true
        horizontalObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self, weak clip] _ in
            guard let self, let clip else { return }
            // Native clip hooks normally prepare before movement. Keep the
            // notification fallback synchronous for other NSClipView hosts.
            if let grid = clip.superview as? GridNativeScrollView, grid.zoomAnchor != nil { return }
            if self.publishHorizontalOffset(clip.bounds.minX) { clip.documentView?.layoutSubtreeIfNeeded() }
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
    var livePosition: (() -> Double)?
    var zoomPosition: Double {
        let value = livePosition?() ?? position
        return value.isFinite ? min(1, max(0, value)) : min(1, max(0, position))
    }
    var cursorX: CGFloat?
    var modelUnitWidth: Double?
    var changeZoom: ((Double, CGFloat) -> Void)?
    var changeTrackHeight: ((Double, Bool) -> Void)?
    private var zoomPersistenceTimer: Timer?
    private var pendingSavedZoom: Double?
    private func persistZoomAfterGesture(_ value: Double) {
        pendingSavedZoom = value
        zoomPersistenceTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in self?.flushSavedZoom() }
        zoomPersistenceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func flushSavedZoom() {
        zoomPersistenceTimer?.invalidate(); zoomPersistenceTimer = nil
        guard let value = pendingSavedZoom else { return }
        pendingSavedZoom = nil
        layoutProfile?.event("zoom-persist-begin", view: self, value: value)
        TimelineViewportPreferences.saveZoom(value)
        layoutProfile?.event("zoom-persist-end", view: self, value: value)
    }
    private var awaitingRenderedZoom: Double?
    func acceptRenderedZoom(_ value: Double) {
        // An older SwiftUI update must not replace the next scale already requested.
        if let requested = awaitingRenderedZoom {
            guard value == requested else { return }
            awaitingRenderedZoom = nil
        }
        if !zoomRunning { zoom = value }
    }
    private var gestureAnchor: Double?
    private var pendingZoom: Double?
    private var wheelZoomTransition: TimelineWheelZoomTransition?
    private var wheelZoomDirection = 0.0
    private var zoomTimer: Timer?
    private var cancelDisplayLink: (() -> Void)?
    private var zoomRunning: Bool { zoomTimer != nil || cancelDisplayLink != nil }
    private weak var zoomGrid: GridNativeScrollView?
    private var lastZoomInput = 0.0
    private var zoomResponse = TimelineZoomResponse()
    private var heightResponse = TimelineTrackHeightResponse()
    private var documentUnitWidth = 1.0
    private var lastFocusRequest: UUID?
    private var pendingFocus: (request: UUID, x: CGFloat)?
    private var focusScheduled = false
    func focus(request: UUID, x: CGFloat?) {
        guard lastFocusRequest != request else { return }
        guard let x, x.isFinite else {
            lastFocusRequest = request; pendingFocus = nil
            return
        }
        pendingFocus = (request, x)
        applyPendingFocus()
    }
    private func schedulePendingFocus() {
        guard pendingFocus != nil, !focusScheduled else { return }
        focusScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusScheduled = false
            self.applyPendingFocus()
        }
    }
    override func layout() {
        super.layout()
        schedulePendingFocus()
    }
    private func applyPendingFocus() {
        guard let pending = pendingFocus, window != nil,
              let horizontal = scrollViews.first, let document = horizontal.documentView,
              document.frame.width > 0, horizontal.contentView.bounds.width > 0 else { return }
        let x = pending.x
        pendingFocus = nil; lastFocusRequest = pending.request
        // The native viewport already has its geometry. Revealing a cursor must
        // not synchronously lay out the whole window or wait for another turn.
        do {
            takeHorizontalControl(horizontal)
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
            if publishHorizontalOffset(horizontal.contentView.bounds.minX) { horizontal.documentView?.layoutSubtreeIfNeeded() }
        }
    }
    private var monitor: Any?
    private var trackpadHorizontal: Bool?
    private var horizontalLimiter = HorizontalScrollLimiter()
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopZoomUpdates(); flushSavedZoom() }
        DispatchQueue.main.async { [weak self] in
            self?.observeVerticalScroll(); self?.observeHorizontalScroll(); self?.applyPendingFocus()
        }
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if window != nil {
            NativeTimelineInputGate.shared.add(self)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleWheelEvent(event) == true ? nil : event
            }
        }
    }
    func timelineInputGateChanged(blocked: Bool) {
        if blocked { stopZoomUpdates(); heightResponse.reset(); trackpadHorizontal = nil }
    }
    @discardableResult func handleWheelEvent(_ event: NSEvent, pressedMouseButtons: Int = NSEvent.pressedMouseButtons) -> Bool {
        guard !interactionBlocked, !NativeTimelineInputGate.shared.isBlocked(window),
              event.window === window, window != nil, window?.attachedSheet == nil,
              visibleRect.contains(convert(event.locationInWindow, from: nil)) else { return false }
        layoutProfile?.event("input-received", view: self, input: event)
        return handle(event, pressedMouseButtons: pressedMouseButtons)
    }
    deinit { zoomPersistenceTimer?.invalidate(); cancelDisplayLink?(); zoomTimer?.invalidate(); if let horizontalObserver { NotificationCenter.default.removeObserver(horizontalObserver) }; if let monitor { NSEvent.removeMonitor(monitor) }; if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) } }
    private var scrollViews: [NSScrollView] {
        var result: [NSScrollView] = []
        var parent = superview
        while let view = parent {
            if let scroll = view as? NSScrollView { result.append(scroll) }
            parent = view.superview
        }
        return result
    }
    private func takeHorizontalControl(_ view: NSScrollView) {
        stopZoomUpdates()
        // A pending scale may still lay out later, but this explicit pan or
        // navigation now owns the viewport. It must prepare and keep its origin.
        (view as? GridNativeScrollView)?.zoomAnchor = nil
    }
    private func scroll(_ view: NSScrollView, x: CGFloat? = nil, y: CGFloat? = nil) {
        guard let document = view.documentView else { return }
        let clip = view.contentView
        var origin = clip.bounds.origin
        if let x { origin.x = min(max(0, x), max(0, document.frame.width - clip.bounds.width)) }
        if let y { origin.y = min(max(0, y), max(0, document.frame.height - clip.bounds.height)) }
        if let grid = view as? GridNativeScrollView { grid.prepareHorizontalViewport(at: origin.x) }
        else if x != nil, publishHorizontalOffset(origin.x) { document.layoutSubtreeIfNeeded() }
        clip.scroll(to: origin)
        view.reflectScrolledClipView(clip)
    }
    private func handle(_ event: NSEvent, pressedMouseButtons: Int) -> Bool {
        let views = scrollViews
        guard let horizontal = views.first else { return false }
        let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
        let shifting = event.modifierFlags.contains(.shift)
        let movement = delta * (event.hasPreciseScrollingDeltas ? (shifting ? 2 : 1) : (shifting ? 54 : 18))
        let heldLeftWheel = pressedMouseButtons & 1 != 0 && !event.hasPreciseScrollingDeltas &&
            event.momentumPhase.isEmpty &&
            event.modifierFlags.intersection([.command, .control, .shift, .option]).isEmpty
        if !event.modifierFlags.intersection([.command, .control]).isEmpty {
            stopZoomUpdates()
            if event.phase.contains(.began) { heightResponse.reset() }
            if event.momentumPhase.isEmpty, event.scrollingDeltaY != 0 {
                changeTrackHeight?(heightResponse.factor(delta: Double(event.scrollingDeltaY), timestamp: event.timestamp,
                    begins: event.phase.contains(.began), precise: event.hasPreciseScrollingDeltas), !event.hasPreciseScrollingDeltas)
            }
        } else if event.modifierFlags.contains(.shift) || heldLeftWheel {
            takeHorizontalControl(horizontal)
            if heldLeftWheel, delta != 0, let window {
                // A ruler/item press must not activate on release after panning.
                NativeTimelineInputGate.shared.cancelPendingClicks(for: window)
            }
            let limited = horizontalLimiter.limit(movement, timestamp: event.timestamp, begins: event.phase.contains(.began), speed: shifting ? 12600 : 4200)
            let origin = horizontal.contentView.bounds.minX
            let target = origin - limited
            if let document = horizontal.documentView, target + horizontal.contentView.bounds.width > document.frame.width - 160 { extend?() }
            scroll(horizontal, x: target)

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
                takeHorizontalControl(horizontal)
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
        // Both devices retain signed native travel and display-frame batching.
        if event.phase.contains(.cancelled) { stopZoomUpdates(); return }
        if event.phase.contains(.began), event.momentumPhase.isEmpty, zoomRunning {
            // Deliver the previous gesture's final delta before resetting its
            // anchor; a zero-delta begin must not silently discard that input.
            if wheelZoomTransition == nil, let zoomGrid { advanceZoom(zoomGrid) }
            stopZoomUpdates()
        }
        if event.momentumPhase.contains(.ended) {
            if let zoomGrid { advanceZoom(zoomGrid) }
            stopZoomUpdates()
            return
        }
        let amount = zoomResponse.change(delta: Double(delta), timestamp: event.timestamp,
            begins: event.phase.contains(.began), precise: event.hasPreciseScrollingDeltas)
        guard delta.isFinite, delta != 0, let grid = horizontal as? GridNativeScrollView,
              let document = horizontal.documentView else { return }
        grid.prioritizeZoom()
        let direction = amount > 0 ? 1.0 : amount < 0 ? -1.0 : 0.0
        if wheelZoomTransition != nil,
           event.hasPreciseScrollingDeltas || (direction != 0 && wheelZoomDirection != 0 && direction != wheelZoomDirection) {
            // Reversal and a change of device start from the visible scale,
            // never from the old mouse transition's unpresented remainder.
            pendingZoom = zoom
            wheelZoomTransition = nil
        }
        if direction != 0 { wheelZoomDirection = event.hasPreciseScrollingDeltas ? 0 : direction }
        // A new movement postpones persistence until this burst is quiet.
        zoomPersistenceTimer?.invalidate(); zoomPersistenceTimer = nil
        // Keep the input burst alive even at a zoom limit.
        lastZoomInput = ProcessInfo.processInfo.systemUptime
        let base = pendingZoom ?? zoom
        let next = min(TimelineZoomLimits.maximum, max(TimelineZoomLimits.minimum, base * exp(amount)))
        if !zoomRunning {
            // Native geometry may lag a newer scale, especially after a fast
            // reversal. Derive the document target from the model, not that
            // intermediate frame; otherwise the anchor can never settle.
            documentUnitWidth = modelUnitWidth ?? ((grid.zoomAnchor?.width ?? document.frame.width) / zoom)
            // The musical position is independent of the rendered scale.
            // cursorX can still belong to the previous layout when a fast new
            // gesture arrives after the native document has changed width.
            let fraction = zoomPosition
            gestureAnchor = fraction
            if next == base {
                // At a limit there is no new layout to center. A real scale
                // change centers only when its new geometry is ready, avoiding
                // a synchronous preparation of an immediately obsolete scale.
                let cursor = CGFloat(fraction) * document.frame.width
                scroll(horizontal, x: cursor - horizontal.contentView.bounds.width / 2)
                publishHorizontalOffset(horizontal.contentView.bounds.minX)
            }
        }
        guard next != base else {
            if !zoomRunning {
                gestureAnchor = nil
                if pendingSavedZoom != nil { persistZoomAfterGesture(zoom) }
            }
            return
        }
        pendingZoom = next
        wheelZoomTransition = event.hasPreciseScrollingDeltas ? nil
            : TimelineWheelZoomTransition(from: zoom, to: next, began: lastZoomInput)
        // The mouse responds immediately and finishes within 90 ms. Precise
        // input keeps its native motion. Both publish at the display cadence.
        if zoomRunning { return }
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
        layoutProfile?.event("zoom-tick", view: self)
        guard let grid = zoomGrid, window != nil, window?.attachedSheet == nil else { stopZoomUpdates(); return }
        advanceZoom(grid)
    }
    private func stopZoomUpdates(preservingVelocity: Bool = false) {
        if zoomRunning {
            layoutProfile?.event("zoom-stop", view: self, value: zoom)
            persistZoomAfterGesture(zoom)
        }
        cancelDisplayLink?()
        cancelDisplayLink = nil
        zoomGrid = nil
        zoomTimer?.invalidate()
        zoomTimer = nil
        pendingZoom = nil
        wheelZoomTransition = nil
        wheelZoomDirection = 0
        gestureAnchor = nil
        if !preservingVelocity { zoomResponse.reset() }
        awaitingRenderedZoom = nil
    }
    private func advanceZoom(_ grid: GridNativeScrollView) {
        guard let target = pendingZoom else { stopZoomUpdates(); return }
        // Keep the scene, waveforms and anchor on one scale on every frame.
        // The mouse transition has an exact deadline and no asymptotic tail.
        if target == zoom {
            wheelZoomTransition = nil
            if ProcessInfo.processInfo.systemUptime - lastZoomInput > 0.08 { stopZoomUpdates(preservingVelocity: true) }
            return
        }
        grid.prioritizeZoom()
        let next = wheelZoomTransition?.value(at: ProcessInfo.processInfo.systemUptime) ?? target
        if next == target { wheelZoomTransition = nil }
        guard next != zoom else { return }
        let fraction = gestureAnchor ?? zoomPosition
        let width = documentUnitWidth * next
        let screenX = grid.contentView.frame.width / 2
        let offset = min(max(0, CGFloat(fraction) * width - screenX), max(0, width - grid.contentView.frame.width))
        grid.zoomAnchor = (fraction, screenX, CGFloat(width))
        zoom = next
        awaitingRenderedZoom = next
        // changeZoom publishes this bucket with the scale. Native bounds
        // notifications are suppressed until the anchor commits, so keep the
        // deduplication state in sync with that publication as well.
        lastHorizontalBucket = floor(max(0, offset) / 512) * 512
        layoutProfile?.event("zoom-publish", view: self, value: next)
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
    private var startY: CGFloat = 0
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
        guard hoverTracking == nil else { return }
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
        startY = event.locationInWindow.y
        previousX = event.locationInWindow.x
        dragging = false
        secondaryClick = event.modifierFlags.contains(.control)
        selectionEdge = areaEdge(event)
    }
    override func mouseDragged(with event: NSEvent) {
        guard !NativeTimelineInputGate.shared.isBlocked(window), let startX, !secondaryClick else { return }
        if !dragging && hypot(event.locationInWindow.x - startX, event.locationInWindow.y - startY) < 3 { return }
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
        guard !NativeTimelineInputGate.shared.isBlocked(window), let startX else { return }
        if hypot(event.locationInWindow.x - startX, event.locationInWindow.y - startY) >= 3 { dragging = true }
        if let selectionEdge {
            if dragging { resizeTime?(fraction(event), selectionEdge) }
        } else if !dragging { move(event, secondary: secondaryClick) }
        selectionEdge = nil
        self.startX = nil
        dragging = false
        NSCursor.openHand.set()
    }
    override func rightMouseDown(with event: NSEvent) {
        guard !NativeTimelineInputGate.shared.isBlocked(window) else { return }
        selectionStart = fraction(event)
        selectionEdge = areaEdge(event)
        startX = event.locationInWindow.x
        startY = event.locationInWindow.y
        selectingTime = false
    }
    override func rightMouseDragged(with event: NSEvent) {
        guard !NativeTimelineInputGate.shared.isBlocked(window), let selectionStart, let startX else { return }
        guard selectingTime || hypot(event.locationInWindow.x - startX, event.locationInWindow.y - startY) >= 3 else { return }
        selectingTime = true
        if let selectionEdge { resizeTime?(fraction(event), selectionEdge) }
        else { selectTime?(selectionStart, fraction(event)) }
    }
    override func rightMouseUp(with event: NSEvent) {
        guard !NativeTimelineInputGate.shared.isBlocked(window), let selectionStart else { return }
        if let startX, hypot(event.locationInWindow.x - startX, event.locationInWindow.y - startY) >= 3 { selectingTime = true }
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
    mutating func limit(_ distance: CGFloat, timestamp: TimeInterval, begins: Bool, speed: Double = 4200) -> CGFloat {
        let elapsed: TimeInterval
        if begins || lastTimestamp == nil {
            elapsed = 1.0 / 60
        } else {
            elapsed = min(1.0 / 30, max(0, timestamp - lastTimestamp!))
        }
        lastTimestamp = timestamp
        let maximum = CGFloat(elapsed * speed)
        return min(maximum, max(-maximum, distance))
    }
}
#endif
