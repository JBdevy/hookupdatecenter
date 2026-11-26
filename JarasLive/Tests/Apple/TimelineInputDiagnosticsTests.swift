import AppKit

_ = NSApplication.shared
let log = URL(fileURLWithPath: TimelineLayoutDiagnostics.logPath)
defer { TimelineLayoutDiagnostics.flush(); try? FileManager.default.removeItem(at: log) }

if !TimelineLayoutDiagnostics.enabled {
    precondition(TimelineLayoutDiagnostics.make("resize-fixture") == nil)
    TimelineLayoutDiagnostics.flush()
    precondition(!FileManager.default.fileExists(atPath: log.path))
    print("TIMELINE_INPUT_DIAGNOSTICS_DISABLED_NO_LOG_OK")
} else {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let divider = NSView(frame: NSRect(x: 180, y: 0, width: 6, height: 300))
    window.contentView!.addSubview(divider)
    let profile = TimelineLayoutDiagnostics.make("resize-fixture")!
    func event(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 150), modifierFlags: [.shift],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    let down = event(.leftMouseDown, x: 183)
    let drag = event(.leftMouseDragged, x: 283)
    let release = event(.leftMouseUp, x: 283)
    profile.event("pointer-down", view: divider, input: down)
    // scrollingDeltaX/Y raise an AppKit exception on these native mouse types.
    // Calling the production logger must return so the resize can continue.
    profile.event("resize-input", view: divider, input: drag, value: 280)
    divider.setFrameOrigin(NSPoint(x: 280, y: 0))
    profile.event("resize-release", view: divider, input: release)
    NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
    NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)

    let wheelCG = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                          wheel1: 14, wheel2: -9, wheel3: 0)!
    let wheel = NSEvent(cgEvent: wheelCG)!
    precondition(wheel.type == .scrollWheel)
    profile.event("wheel-input", view: divider, input: wheel)
    TimelineLayoutDiagnostics.flush()
    let rows = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
        try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
    }
    for name in ["pointer-down", "resize-input", "resize-release"] {
        let row = rows.first { $0["event"] as? String == name }!
        precondition(row["deltaX"] == nil && row["deltaY"] == nil, "Mouse input must not read scroll-only fields")
        precondition((row["inputTimestampMS"] as? Double ?? 0) > 0)
        precondition((row["inputAgeMS"] as? Double ?? -1) >= 0)
        precondition(row["modifiers"] as? UInt == NSEvent.ModifierFlags.shift.rawValue)
    }
    let wheelRow = rows.first { $0["event"] as? String == "wheel-input" }!
    precondition(wheelRow["deltaX"] as? Double == Double(wheel.scrollingDeltaX))
    precondition(wheelRow["deltaY"] as? Double == Double(wheel.scrollingDeltaY))
    let updates = rows.filter { $0["event"] as? String == "resize-window-update" }
    precondition(updates.count == 1, "Window update must consume each pending resize sample once")
    precondition(updates[0]["value"] as? Double == 280 && updates[0]["width"] as? Double == 6)
    precondition(updates[0]["inputTimestampMS"] as? Double == drag.timestamp * 1000)
    precondition((updates[0]["durationMS"] as? Double ?? -1) >= 0)
    precondition(divider.frame.minX == 280, "Instrumentation interrupted resize work")
    window.close()
    print("TIMELINE_INPUT_DIAGNOSTICS_MOUSE_DOWN_DRAG_RELEASE_WHEEL_AND_WINDOW_UPDATE_OK")
}
