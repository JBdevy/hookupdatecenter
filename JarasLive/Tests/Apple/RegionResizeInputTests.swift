import AppKit

@MainActor func run() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 100), styleMask: .borderless, backing: .buffered, defer: false)
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
    window.contentView = host
    let view = RegionRightClickView(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
    host.addSubview(view)
    func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    view.mouseEntered(with: event(.mouseMoved, 8))
    precondition(NSCursor.current == .resizeLeftRight, "region left edge advertises resizing")
    view.mouseMoved(with: event(.mouseMoved, 110))
    precondition(NSCursor.current == .arrow, "moving from an edge into the same region restores the arrow")
    view.mouseMoved(with: event(.mouseMoved, 212))
    precondition(NSCursor.current == .resizeLeftRight, "region right edge advertises resizing")
    view.mouseExited(with: event(.mouseMoved, 225))
    precondition(NSCursor.current == .arrow, "leaving the region cannot retain its resize cursor")
    view.mouseMoved(with: event(.mouseMoved, 225))
    precondition(NSCursor.current == .arrow, "outside points are not region resize handles")
    view.resizable = false
    view.mouseMoved(with: event(.mouseMoved, 8))
    precondition(NSCursor.current == .arrow, "non-resizable regions never advertise resizing")
    view.resizable = true
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
    var regionSeeks = 0
    view.seek = { regionSeeks += 1 }
    view.mouseDown(with: event(.leftMouseDown, 110))
    precondition(regionSeeks == 0, "region seek waits for mouse-up")
    view.mouseUp(with: event(.leftMouseUp, 110))
    precondition(regionSeeks == 1, "ordinary region clicks seek its start")
    view.mouseDown(with: event(.leftMouseDown, 110))
    view.mouseDragged(with: event(.leftMouseDragged, 140))
    view.mouseUp(with: event(.leftMouseUp, 110))
    precondition(regionSeeks == 1, "a region drag returning to its origin must never become a seek")
    for modal in [false, true] {
        view.mouseDown(with: event(.leftMouseDown, 110))
        if modal {
            NativeTimelineInputGate.shared.setBlocked(true, for: window)
            NativeTimelineInputGate.shared.setBlocked(false, for: window)
        } else { NativeTimelineInputGate.shared.cancelPendingClicks(for: window) }
        view.mouseUp(with: event(.leftMouseUp, 110))
    }
    precondition(regionSeeks == 1, "region presses cancelled by wheel or modal cannot seek on release")
    view.mouseDown(with: event(.leftMouseDown, 110))
    view.mouseDragged(with: event(.leftMouseDragged, 110, 18))
    view.mouseUp(with: event(.leftMouseUp, 110))
    precondition(regionSeeks == 1, "vertical region drags also leave the cursor unchanged")
    let dragCount = replacement.count
    view.mouseDown(with: event(.leftMouseDown, 110, flags: .option))
    precondition(deletes == 0 && regionSeeks == 1, "Option click waits for release and does not seek")
    view.mouseUp(with: event(.leftMouseUp, 110, flags: .option))
    precondition(deletes == 1 && regionSeeks == 1)
    view.mouseDown(with: event(.leftMouseDown, 110, flags: .option))
    view.mouseDragged(with: event(.leftMouseDragged, 140, flags: .option))
    view.mouseUp(with: event(.leftMouseUp, 110, flags: .option))
    precondition(deletes == 1 && replacement.count == dragCount, "Option drag cannot delete, seek or move the region")
    view.mouseDown(with: event(.leftMouseDown, 110, flags: .option))
    NativeTimelineInputGate.shared.cancelPendingClicks(for: window)
    view.mouseUp(with: event(.leftMouseUp, 110, flags: .option))
    precondition(deletes == 1, "cancelled Option clicks cannot delete")
    deletes = 0
    var exports = 0
    view.exportAudio = { exports += 1 }
    let exportMenu = view.regionMenu()
    let exportItem = exportMenu.items.first { $0.action == NSSelectorFromString("exportAudioSelected") }!
    NSApp.sendAction(exportItem.action!, to: exportItem.target, from: exportItem)
    precondition(exports == 1, "Export menu dispatches exactly once")
    view.exportAudio = nil
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
    func markerEvent(_ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = [], x: CGFloat = 305, y: CGFloat = 5) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    let router = RightClickRouter.shared
    var markerSeeks = 0; marker.seek = { markerSeeks += 1 }
    marker.mouseDown(with: markerEvent(.leftMouseDown))
    precondition(markerSeeks == 0, "locked/unified marker flags also wait for release")
    marker.mouseUp(with: markerEvent(.leftMouseUp))
    precondition(markerSeeks == 1, "marker flag release seeks the marker itself")
    marker.mouseDown(with: markerEvent(.leftMouseDown))
    marker.mouseDragged(with: markerEvent(.leftMouseDragged, x: 330))
    marker.mouseDragged(with: markerEvent(.leftMouseDragged))
    marker.mouseUp(with: markerEvent(.leftMouseUp))
    precondition(markerSeeks == 1, "dragging a locked marker never seeks, even after returning to its origin")
    for modal in [false, true] {
        marker.mouseDown(with: markerEvent(.leftMouseDown))
        if modal {
            NativeTimelineInputGate.shared.setBlocked(true, for: window)
            NativeTimelineInputGate.shared.setBlocked(false, for: window)
        } else { NativeTimelineInputGate.shared.cancelPendingClicks(for: window) }
        marker.mouseUp(with: markerEvent(.leftMouseUp))
    }
    precondition(markerSeeks == 1, "marker cancellation cannot leave a latent seek")
    marker.mouseDown(with: markerEvent(.leftMouseDown))
    marker.mouseDragged(with: markerEvent(.leftMouseDragged, y: 18))
    marker.mouseUp(with: markerEvent(.leftMouseUp))
    precondition(markerSeeks == 1, "vertical locked-marker drags cannot become clicks")
    marker.mouseDown(with: markerEvent(.leftMouseDown, flags: .option))
    precondition(markerSeeks == 1, "marker deletion must not move the cursor")
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
    marker.isHidden = false
    var markerDrags: [(CGFloat, Bool)] = [], swappedDrags: [(CGFloat, Bool)] = []
    marker.drag = { markerDrags.append(($0, $1)) }
    precondition(MarkerEditClickView.usesMoveCursor(for: markerEvent(.mouseMoved)), "ruler hover recognizes the tempo display above it")
    precondition(!MarkerEditClickView.usesMoveCursor(for: markerEvent(.mouseMoved, x: 250)), "ruler hover outside a tempo display is unaffected")
    marker.interactionBlocked = true
    precondition(!MarkerEditClickView.usesMoveCursor(for: markerEvent(.mouseMoved)), "modal blocking also disables the tempo hover cursor")
    marker.interactionBlocked = false
    marker.mouseEntered(with: markerEvent(.mouseMoved))
    precondition(NSCursor.current == NSCursor.resizeLeftRight, "tempo displays show the horizontal-move cursor immediately on hover")
    marker.mouseExited(with: markerEvent(.mouseMoved))
    precondition(NSCursor.current == NSCursor.arrow, "leaving the tempo display restores the normal cursor")
    marker.mouseDown(with: markerEvent(.leftMouseDown, x: 305))
    marker.mouseDragged(with: markerEvent(.leftMouseDragged, x: 321.375))
    marker.frame.origin.x = 316.375
    marker.drag = { swappedDrags.append(($0, $1)) }
    marker.mouseDragged(with: markerEvent(.leftMouseDragged, x: 290.625))
    marker.mouseUp(with: markerEvent(.leftMouseUp, x: 299.875))
    precondition(markerDrags.map { $0.0 } == [16.375, -14.375, -5.125], "tempo drag preserves fractional displacement in both directions despite relocated target")
    precondition(markerDrags.map { $0.1 } == [false, false, true] && swappedDrags.isEmpty, "tempo drag captures original timing callback and commits only on release")
    precondition(markerSeeks == 1, "dragging tempo markers cannot seek the edit cursor")
    marker.mouseUp(with: markerEvent(.leftMouseUp))
    precondition(markerDrags.count == 3, "tempo drag cannot commit twice")
    marker.mouseDown(with: markerEvent(.leftMouseDown))
    marker.mouseUp(with: markerEvent(.leftMouseUp, x: 306))
    precondition(markerSeeks == 2 && swappedDrags.isEmpty, "simple tempo clicks seek without modifying the marker")
    marker.interactionBlocked = true
    marker.mouseDown(with: markerEvent(.leftMouseDown))
    marker.mouseDragged(with: markerEvent(.leftMouseDragged, x: 340))
    marker.mouseUp(with: markerEvent(.leftMouseUp, x: 340))
    precondition(swappedDrags.isEmpty, "blocked marker input must never move tempo markers")
    print("REGION_INPUT_OK: resize, captured drag, edit/delete menus, Option marker deletion, free tempo-marker drag and blocked input")
}
MainActor.assumeIsolated { run() }
