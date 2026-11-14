import AppKit

final class WheelRoot: NSView {
    var hits = 0
    override func hitTest(_ point: NSPoint) -> NSView? { hits += 1; return super.hitTest(point) }
}
final class WheelDocument: NSView { override var isFlipped: Bool { true } }
final class WheelInput: NSEvent {
    var target: NSWindow!
    var point = NSPoint(x: 100, y: 100)
    var time = 100.0
    var state: NSEvent.Phase = []
    var dy: CGFloat = -0.25
    override var window: NSWindow? { target }
    override var locationInWindow: NSPoint { point }
    override var timestamp: TimeInterval { time }
    override var phase: NSEvent.Phase { state }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
    override var scrollingDeltaY: CGFloat { dy }
    override var type: NSEvent.EventType { .scrollWheel }
    override var scrollingDeltaX: CGFloat { 0 }
    override var momentumPhase: NSEvent.Phase { [] }
    override var hasPreciseScrollingDeltas: Bool { true }
}
MainActor.assumeIsolated {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let root = WheelRoot(frame: window.contentView!.bounds)
    window.contentView = root
    let scroll = NSScrollView(frame: root.bounds)
    scroll.documentView = WheelDocument(frame: NSRect(x: 0, y: 0, width: 300, height: 2000))
    root.addSubview(scroll)
    let controller = SidebarScrollController(); controller.attach(scroll)
    let wheel = WheelInput(); wheel.target = window
    precondition(controller.handleWheel(wheel))
    for _ in 0..<100 {
        wheel.time += 0.001
        precondition(controller.handleWheel(wheel))
    }
    precondition(root.hits == 1, "continuous wheel input must not traverse the entire window for every delta")
    precondition(abs(controller.metrics.offset - 25.25) < 0.01, "every delta is applied exactly once")
    wheel.point.x += 20; wheel.time += 0.001
    precondition(controller.handleWheel(wheel) && root.hits == 2, "a moved pointer resolves its current destination")
    wheel.time += 0.2
    precondition(controller.handleWheel(wheel) && root.hits == 3, "an idle wheel starts a fresh route")
    wheel.state = .began; wheel.time += 0.001
    precondition(controller.handleWheel(wheel) && root.hits == 4, "a new trackpad gesture starts a fresh route")
    wheel.state = []
    let overlay = NSScrollView(frame: root.bounds)
    overlay.documentView = WheelDocument(frame: NSRect(x: 0, y: 0, width: 300, height: 1000))
    root.addSubview(overlay)
    controller.invalidateWheelTarget() // The click/key opening a panel invalidates the gesture.
    wheel.time += 0.001
    let before = controller.metrics.offset
    precondition(!controller.handleWheel(wheel) && controller.metrics.offset == before, "an overlaid list owns its wheel")
    overlay.removeFromSuperview(); wheel.time += 0.001
    precondition(controller.handleWheel(wheel), "removing a cached overlay restores the underlying list")
    controller.attach(nil)
    precondition(!controller.handleWheel(wheel))
    let limited = SidebarScrollController(limitsScrollVelocity: true)
    limited.attach(scroll)
    wheel.dy = -1000; wheel.time = 200
    let start = limited.metrics.offset
    precondition(limited.handleWheel(wheel))
    for _ in 0..<120 { wheel.time += 1.0/120; precondition(limited.handleWheel(wheel)) }
    let maximum = NativeMixerScrollVelocity.maximum(viewport: scroll.contentView.bounds.height)
    precondition(limited.metrics.offset > start && limited.metrics.offset-start <= maximum * 1.02,
                 "A long fast gesture must remain bounded by viewport speed")
    let stopped = limited.metrics.offset
    RunLoop.main.run(until: Date().addingTimeInterval(0.04))
    precondition(abs(limited.metrics.offset-stopped) <= 1/window.backingScaleFactor, "Only native pixel alignment may change the resting offset")
    let restingOffset = limited.metrics.offset
    RunLoop.main.run(until: Date().addingTimeInterval(0.04))
    precondition(limited.metrics.offset == restingOffset, "Discarded flick distance must never become delayed movement")
    wheel.dy = 1; wheel.time += 0.02
    precondition(limited.handleWheel(wheel) && limited.metrics.offset == restingOffset-1,
                 "Small reversals must respond immediately after a capped gesture")
    let duplicateOffset = limited.metrics.offset
    wheel.dy = -1000
    precondition(limited.handleWheel(wheel) && limited.metrics.offset == duplicateOffset,
                 "A duplicate timestamp must be consumed rather than falling back to unlimited native movement")
    limited.attach(nil)
    print("TRACK_MIXER_VELOCITY_CAP_IMMEDIATE_REVERSE_AND_NO_DELAYED_TRAVEL_OK")
    controller.attach(scroll)
    let header: CGFloat = 80, row: CGFloat = 64
    scroll.documentView?.setFrameSize(CGSize(width: 300, height: header + row * 902))
    controller.scroll(to: 0)
    for count in 896...900 {
        let top = CGFloat(count - 1) * row
        controller.revealRow(offset: top, height: row, pinnedHeaderHeight: header)
        precondition(top >= controller.metrics.offset &&
                     top + header + row <= controller.metrics.offset + controller.metrics.viewportHeight,
                     "The newest copy must be fully visible below the fixed toolbar")
    }
    controller.revealRow(offset: row * 5, height: row, pinnedHeaderHeight: header)
    precondition(controller.metrics.offset == row * 5, "An earlier copy must scroll back to its header")
    controller.revealRow(offset: row * 12, height: 600, pinnedHeaderHeight: header)
    precondition(controller.metrics.offset == row * 12, "A tall row must reveal its name and controls")
    controller.revealRow(offset: 0, height: row, pinnedHeaderHeight: header)
    precondition(controller.metrics.offset == 0, "The first row must remain reachable")
    controller.attach(nil)
    print("TRACK_MIXER_COPY_FOLLOW_900_ROWS_AND_FIXED_HEADER_OK")
    window.close()
    print("SIDEBAR_WHEEL_ROUTING_REUSES_GESTURE_PRESERVES_DELTAS_POINTER_GAPS_OVERLAYS_OK")
}
