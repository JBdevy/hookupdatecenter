import AppKit

final class QueuedInput: NSEvent {
    var kind: NSEvent.EventType = .scrollWheel
    var target: NSWindow?
    var point = NSPoint(x: 100, y: 100)
    var time = 1.0
    var x: CGFloat = 0, y: CGFloat = -1
    var flags: NSEvent.ModifierFlags = []
    var gesture: NSEvent.Phase = .changed
    override var type: NSEvent.EventType { kind }
    override var window: NSWindow? { target }
    override var locationInWindow: NSPoint { point }
    override var timestamp: TimeInterval { time }
    override var scrollingDeltaX: CGFloat { x }
    override var scrollingDeltaY: CGFloat { y }
    override var modifierFlags: NSEvent.ModifierFlags { flags }
    override var phase: NSEvent.Phase { gesture }
    override var momentumPhase: NSEvent.Phase { [] }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var buttonNumber: Int { 0 }
}
MainActor.assumeIsolated {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    func event(_ type: NSEvent.EventType = .scrollWheel, y: CGFloat = -1, time: Double = 1) -> QueuedInput {
        let input = QueuedInput(); input.kind = type; input.target = window; input.y = y; input.time = time; return input
    }
    var queue: [QueuedInput] = []
    func read(_ dequeue: Bool) -> NSEvent? { guard let first = queue.first else { return nil }; if dequeue { queue.removeFirst() }; return first }
    let first = event(y: -2)
    queue = (1...40).map { event(y: -3, time: 1 + Double($0) / 1000) }
    let key = event(.keyDown, time: 2); queue.append(key)
    let batch = NativeTimelineEventQueue.wheel(first, read: read)
    precondition(batch.count == 41 && batch.y == -122 && queue.first === key,
                 "queued deltas are preserved in one update without consuming the following shortcut")
    for stop in [event(y: 2), event(.leftMouseUp), event(.keyDown)] {
        queue = [stop]
        precondition(NativeTimelineEventQueue.wheel(first, read: read).count == 1 && queue.first === stop)
    }
    let moved = event(); moved.point.x += 30; queue = [moved]
    precondition(NativeTimelineEventQueue.wheel(first, read: read).count == 1, "a different panel/pointer location starts its own route")
    let horizontal = event(y: 0); horizontal.x = -4; queue = [horizontal]
    precondition(NativeTimelineEventQueue.wheel(first, read: read).count == 1, "nested FX scrolling must not merge with horizontal panning")
    let ended = event(); ended.gesture = .ended; queue = [ended]
    precondition(NativeTimelineEventQueue.wheel(first, read: read).count == 1 && queue.first === ended)
    queue = (1...100).map { event(time: 1 + Double($0) / 1000) }
    precondition(NativeTimelineEventQueue.wheel(first, read: read).count == 65 && queue.count == 36, "input draining has a bounded per-event cost")
    let drag = event(.leftMouseDragged)
    let finalDrag = event(.leftMouseDragged, time: 1.2)
    let up = event(.leftMouseUp, time: 1.3)
    queue = [event(.leftMouseDragged, time: 1.1), finalDrag, up, event(.leftMouseDragged, time: 1.4)]
    precondition(NativeTimelineEventQueue.latestDrag(drag, read: read) === finalDrag && queue.first === up,
                 "resize uses the newest consecutive destination but never crosses mouse-up into another drag")
    // Also exercise AppKit's actual queue rather than only the deterministic reader.
    let app = NSApplication.shared
    while app.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) != nil {}
    func nativeWheel() -> NSEvent {
        NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0)!)!
    }
    let nativeFirst = nativeWheel(), nativeSecond = nativeWheel(), nativeThird = nativeWheel()
    let nativeKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: "d", charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2)!
    for input in [nativeSecond, nativeThird, nativeKey] { app.postEvent(input, atStart: false) }
    let nativeBatch = NativeTimelineEventQueue.wheel(nativeFirst)
    precondition(nativeBatch.count == 3 && nativeBatch.y == nativeFirst.scrollingDeltaY + nativeSecond.scrollingDeltaY + nativeThird.scrollingDeltaY,
                 "the default reader must drain adjacent wheel events from the real AppKit queue")
    precondition(app.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true)?.type == .keyDown,
                 "the actual queued shortcut remains available to its usual handler")
    window.close()
    print("NATIVE_INPUT_BACKLOG_COALESCES_DELTAS_AND_RESIZE_PRESERVES_SHORTCUTS_PANELS_PHASES_MOUSE_UP_OK")
}
