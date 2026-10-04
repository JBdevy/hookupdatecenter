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
    precondition(values.last == 147, "Layout changes cannot feed back into drag distance")
    view.mouseDragged(with: event(.leftMouseDragged, y: -100))
    precondition(values.last == 27)
    view.mouseDragged(with: event(.leftMouseDragged, y: 900))
    precondition(values.last == 400)
    view.mouseUp(with: event(.leftMouseUp, y: 212))
    precondition(committed == 227)
    let count = values.count
    view.mouseDragged(with: event(.leftMouseDragged, y: 400))
    precondition(values.count == count, "Mouse-up ends the resize")
    print("FOOTER_DISPLAY_DRAG_EXACT_DISTANCE_LIMITS_AND_COMMIT_OK")
}
