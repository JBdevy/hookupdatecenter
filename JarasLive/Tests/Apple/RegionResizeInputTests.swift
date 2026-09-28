import AppKit

@MainActor func run() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
    window.contentView = host
    let view = RegionRightClickView(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
    host.addSubview(view)
    func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    var original: [(CGFloat, Bool, Int)] = [], replacement: [(CGFloat, Bool, Int)] = []
    view.drag = { original.append(($0, $1, $2)) }
    // Grab beside the cap and above its painted band; keep the captured edge
    // and callback even while SwiftUI moves/resizes the view during preview.
    view.mouseDown(with: event(.leftMouseDown, 32))
    view.mouseDragged(with: event(.leftMouseDragged, 50))
    view.frame = NSRect(x: 30, y: 0, width: 200, height: 24)
    view.drag = { replacement.append(($0, $1, $2)) }
    view.mouseDragged(with: event(.leftMouseDragged, 51))
    view.mouseUp(with: event(.leftMouseUp, 52))
    precondition(original.map { $0.0 } == [18, 19, 20] && original.allSatisfy { $0.2 == -1 })
    precondition(original.map { $0.1 } == [false, false, true] && replacement.isEmpty, "preview must not replace the gesture's captured callback")
    view.mouseDown(with: event(.leftMouseDown, 220))
    view.mouseDragged(with: event(.leftMouseDragged, 235))
    view.mouseUp(with: event(.leftMouseUp, 236))
    precondition(replacement.map { $0.0 } == [15, 16] && replacement.allSatisfy { $0.2 == 1 }, "right cap uses window displacement despite preview movement")
    replacement.removeAll()
    view.resizable = false
    view.mouseDown(with: event(.leftMouseDown, 32))
    view.mouseDragged(with: event(.leftMouseDragged, 42))
    view.mouseUp(with: event(.leftMouseUp, 42))
    precondition(replacement.count == 2 && replacement.allSatisfy { $0.2 == 0 }, "unified cap must move the group, never resize it")
    let count = replacement.count
    view.mouseUp(with: event(.leftMouseUp, 42))
    precondition(replacement.count == count, "released gesture cannot commit twice")
    var edits = 0, deletes = 0
    view.edit = { edits += 1 }; view.delete = { deletes += 1 }
    let menu = view.regionMenu()
    precondition(menu.items.count == 2, "normal regions offer edit and delete before opening an editor")
    for item in menu.items { NSApp.sendAction(item.action!, to: item.target, from: item) }
    precondition(edits == 1 && deletes == 1)
    view.disunify = {}
    precondition(view.regionMenu().items.count == 3, "special regions keep edit, disunify and delete")
    let marker = MarkerEditClickView(frame: NSRect(x: 300, y: 0, width: 80, height: 16))
    host.addSubview(marker)
    var markerEdits = 0, markerDeletes = 0
    marker.action = { markerEdits += 1 }; marker.optionClick = { markerDeletes += 1 }
    func markerEvent(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = [], x: CGFloat = 305) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 5), modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    let router = RightClickRouter.shared
    precondition(!router.handle(markerEvent(.leftMouseDown)), "ordinary clicks keep positioning the edit cursor")
    precondition(router.handle(markerEvent(.leftMouseDown, flags: .option)))
    precondition(markerDeletes == 1 && markerEdits == 0, "Option click deletes without opening the editor")
    precondition(router.handle(markerEvent(.rightMouseDown)))
    precondition(markerEdits == 1 && markerDeletes == 1)
    precondition(!router.handle(markerEvent(.leftMouseDown, flags: .option, x: 250)), "Option click outside a marker must not be swallowed")
    marker.interactionBlocked = true
    precondition(!router.handle(markerEvent(.leftMouseDown, flags: .option)))
    marker.interactionBlocked = false; marker.isHidden = true
    precondition(!router.handle(markerEvent(.leftMouseDown, flags: .option)))
    print("REGION_INPUT_OK: resize, captured drag, edit/delete menus, Option marker deletion and blocked input")
}
MainActor.assumeIsolated { run() }
