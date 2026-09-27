#if os(macOS)
import SwiftUI
import AppKit

/// Observes only wheel events over this timeline; clicks and playhead drags pass through.
struct TimelineWheelInput: NSViewRepresentable {
    @Binding var zoom: Double
    let position: Double
    func makeNSView(context: Context) -> TimelineWheelView { TimelineWheelView() }
    func updateNSView(_ view: TimelineWheelView, context: Context) {
        view.zoom = zoom
        view.position = position
        view.changeZoom = { zoom = $0 }
        view.applyPendingAnchor()
    }
}
final class TimelineWheelView: NSView {
    var zoom = 1.0
    var position = 0.0
    var changeZoom: ((Double) -> Void)?
    private var monitor: Any?
    private var pendingAnchor: (fraction: Double, screenX: CGFloat)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if window != nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window,
                      self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                return self.handle(event) ? nil : event
            }
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
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
        if event.modifierFlags.contains(.shift) {
            scroll(horizontal, x: horizontal.contentView.bounds.minX - movement)
        } else if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            if let vertical = views.dropFirst().first { scroll(vertical, y: vertical.contentView.bounds.minY - movement) }
        } else {
            guard event.momentumPhase == [] else { return true }
            let next = min(4, max(1, zoom * exp(Double(delta) * (event.hasPreciseScrollingDeltas ? 0.008 : 0.12))))
            guard next != zoom else { return true }
            let clip = horizontal.contentView
            let fraction = min(1, max(0, position))
            let currentX = CGFloat(fraction) * bounds.width - clip.bounds.minX
            pendingAnchor = (fraction, min(clip.bounds.width, max(0, currentX)))
            zoom = next
            changeZoom?(next)
        }
        return true
    }
    func applyPendingAnchor() {
        guard pendingAnchor != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let anchor = self.pendingAnchor, let horizontal = self.scrollViews.first else { return }
            self.window?.contentView?.layoutSubtreeIfNeeded()
            self.scroll(horizontal, x: CGFloat(anchor.fraction) * self.bounds.width - anchor.screenX)
            self.pendingAnchor = nil
        }
    }
}
/// Limited to the numbered ruler. Clip clicks never enter this view.
struct TimelineRulerInput: NSViewRepresentable {
    let seek: (Double, Bool) -> Void
    func makeNSView(context: Context) -> TimelineRulerView { TimelineRulerView() }
    func updateNSView(_ view: TimelineRulerView, context: Context) { view.seek = seek }
}
final class TimelineRulerView: NSView {
    var seek: ((Double, Bool) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { move(event, secondary: event.modifierFlags.contains(.control)) }
    override func rightMouseDown(with event: NSEvent) { move(event, secondary: true) }
    private func move(_ event: NSEvent, secondary: Bool) {
        let x = convert(event.locationInWindow, from: nil).x
        seek?(Double(min(1, max(0, x / max(1, bounds.width)))), secondary)
    }
}
#endif
