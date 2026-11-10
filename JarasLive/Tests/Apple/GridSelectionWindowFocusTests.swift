import AppKit

final class AutomationLaneView: NSView, TimelineGridKeyboardTarget {}
final class PlaylistSelectionNotice {
    static let shared = PlaylistSelectionNotice()
    func present(_ name: String, in window: NSWindow) {}
}

// Use real key windows and NSApplication dispatch. A fixture which overrides
// isKeyWindow cannot detect a selection monitor bypassing window activation.
MainActor.assumeIsolated {
let app = NSApplication.shared
let previous = NSWorkspace.shared.frontmostApplication
app.setActivationPolicy(.accessory)
let document = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 800, height: 600),
                        styleMask: [.titled], backing: .buffered, defer: false)
let tool = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 300, height: 200),
                    styleMask: [.titled], backing: .buffered, defer: false)
document.isReleasedWhenClosed = false; tool.isReleasedWhenClosed = false
let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
document.contentView = root
let area = EditorSelectionAreaView(frame: root.bounds)
area.scope = .grid; root.addSubview(area)
let shortcuts = RegionShortcutView(frame: root.bounds); root.addSubview(shortcuts)
let grid = GridSelectionView(frame: root.bounds); root.addSubview(grid)
grid.headerHeight = 40
let item = UUID()
grid.items = [GridSelectionItem(id: item, rect: CGRect(x: 100, y: 100, width: 300, height: 80),
                                editable: false, contextActions: false)]
grid.pointerDown = { EditorSelectionRouter.shared.handlePointer($0) }
var deleted = 0
shortcuts.hasDeletionSelection = {
    !grid.selected.isEmpty && EditorSelectionRouter.shared.activeScope(in: NSApp.keyWindow) == .grid
}
shortcuts.delete = { deleted += 1; grid.selected = [] }
var failures: [String] = []
func check(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}
func pointer(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: grid.convert(point, to: nil), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: document.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
}
func finish() -> Never {
    document.close(); tool.close()
    previous?.activate(options: [])
    for failure in failures { print("FAIL: \(failure)") }
    if failures.isEmpty { print("GRID_BACKGROUND_WINDOW_SELECTION_RECEIVES_DELETE_OK") }
    exit(failures.isEmpty ? 0 : 1)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
    failures.append("AppKit window activation timed out")
    finish()
}
DispatchQueue.main.async {
    document.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        document.makeKey()
        tool.makeKeyAndOrderFront(nil)
        check(tool.isKeyWindow && !document.isKeyWindow, "fixture starts with another window receiving keys")

        // Rejected input must not move keyboard focus to the document.
        NativeTimelineInputGate.shared.setBlocked(true, for: document)
        check(!grid.handlePointerEvent(pointer(.leftMouseDown, CGPoint(x: 220, y: 145))), "modal rejects clicks")
        NativeTimelineInputGate.shared.setBlocked(false, for: document)
        check(!grid.handlePointerEvent(pointer(.leftMouseDown, CGPoint(x: 220, y: 20))), "ruler stays outside the body handler")
        check(tool.isKeyWindow && grid.selected.isEmpty, "rejected clicks preserve focus and selection")

        // Both a direct item click and a marquee must bring subsequent Delete
        // to the project, even though the native monitor consumed the mouse event.
        for marquee in [false, true] {
            tool.makeKeyAndOrderFront(nil)
            let expectedDeletes = deleted + 1
            if marquee {
                app.sendEvent(pointer(.rightMouseDown, CGPoint(x: 80, y: 80)))
                app.sendEvent(pointer(.rightMouseDragged, CGPoint(x: 420, y: 200)))
                app.sendEvent(pointer(.rightMouseUp, CGPoint(x: 420, y: 200)))
            } else {
                app.sendEvent(pointer(.leftMouseDown, CGPoint(x: 220, y: 145)))
                app.sendEvent(pointer(.leftMouseUp, CGPoint(x: 220, y: 145)))
            }
            check(grid.selected == [item], "pointer selects the item")
            check(document.isKeyWindow && !tool.isKeyWindow, "selection activates the document window")
            check(document.firstResponder === grid, "grid receives keyboard focus")
            if let receiver = app.keyWindow {
                app.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: receiver.windowNumber, context: nil, characters: "\u{7f}",
                    charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!)
            }
            check(deleted == expectedDeletes && grid.selected.isEmpty, "Delete reaches the selected item immediately")
        }
        finish()
    }
}
app.run()
}
