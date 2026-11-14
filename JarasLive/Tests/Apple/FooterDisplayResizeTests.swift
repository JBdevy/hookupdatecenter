import AppKit

// INSERT_FOOTER_RESIZE_VIEW

MainActor.assumeIsolated {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let view = FooterDisplayResizeView(frame: NSRect(x: 100, y: 0, width: 400, height: 27))
    window.contentView!.addSubview(view)
    var values: [CGFloat] = [], committed: CGFloat?
    view.height = 27; view.maximum = 400
    view.changed = { values.append($0) }; view.ended = { committed = $0 }
    func event(_ type: NSEvent.EventType, y: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: 200, y: y), modifierFlags: [], timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    view.mouseDown(with: event(.leftMouseDown, y: 12))
    view.mouseDragged(with: event(.leftMouseDragged, y: 112))
    precondition(values.last == 127)
    view.height = 127; view.setFrameSize(NSSize(width: 400, height: 127))
    view.mouseDragged(with: event(.leftMouseDragged, y: 132))
    RunLoop.main.run(until: Date().addingTimeInterval(0.025))
    precondition(values.last == 147, "Layout changes cannot feed back into drag distance")
    view.mouseDragged(with: event(.leftMouseDragged, y: -100))
    RunLoop.main.run(until: Date().addingTimeInterval(0.025))
    precondition(values.last == 27)
    view.mouseDragged(with: event(.leftMouseDragged, y: 900))
    RunLoop.main.run(until: Date().addingTimeInterval(0.025))
    precondition(values.last == 400)
    view.mouseUp(with: event(.leftMouseUp, y: 212))
    precondition(committed == 227)
    let count = values.count
    view.mouseDragged(with: event(.leftMouseDragged, y: 400))
    precondition(values.count == count, "Mouse-up ends the resize")
    print("FOOTER_DISPLAY_DRAG_EXACT_DISTANCE_LIMITS_AND_COMMIT_OK")

    // A burst is reduced to its latest position without leaving a movement
    // queue after release or cancellation.
    view.height = 27; values.removeAll(); committed = nil
    view.mouseDown(with: event(.leftMouseDown, y: 12))
    view.mouseDragged(with: event(.leftMouseDragged, y: 13))
    for y: CGFloat in stride(from: 14, through: 112, by: 1) { view.mouseDragged(with: event(.leftMouseDragged, y: y)) }
    precondition(values.count == 1, "A pointer burst must not force one full-window layout per sample")
    RunLoop.main.run(until: Date().addingTimeInterval(0.025))
    precondition(values == [28, 127], "Only the newest queued height reaches the next frame")
    view.mouseDragged(with: event(.leftMouseDragged, y: 150))
    view.mouseUp(with: event(.leftMouseUp, y: 130))
    precondition(committed == 145 && values.last == 145, "Release commits its own exact coordinate before a pending frame")
    let released = values
    RunLoop.main.run(until: Date().addingTimeInterval(0.04))
    precondition(values == released, "No delayed movement remains after release")
    view.mouseDown(with: event(.leftMouseDown, y: 12))
    view.mouseDragged(with: event(.leftMouseDragged, y: 20))
    view.mouseDragged(with: event(.leftMouseDragged, y: 50))
    view.cancelDrag()
    let cancelled = values
    RunLoop.main.run(until: Date().addingTimeInterval(0.04))
    precondition(values == cancelled, "Cancel discards pending display work")
    print("FOOTER_DISPLAY_BURST_COALESCING_EXACT_RELEASE_AND_CANCEL_NO_TAIL_OK")
}
