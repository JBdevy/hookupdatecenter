import AppKit

@main struct FXSlotPointerTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        window.contentView = root
        let slot = RightClickTargetView(frame: NSRect(x: 10, y: 10, width: 100, height: 20))
        root.addSubview(slot)
        var bypass = 0, removed = 0, menu = 0
        slot.shiftClick = { bypass += 1 }; slot.optionClick = { removed += 1 }; slot.action = { menu += 1 }
        func event(_ flags: NSEvent.ModifierFlags, x: CGFloat = 30) -> NSEvent {
            NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: x, y: 20), modifierFlags: flags,
                              timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let router = RightClickRouter.shared
        precondition(!router.handle(event([])), "plain clicks reach the plugin button")
        precondition(router.handlesModifiedLeftClick(event(.shift)), "slot shortcuts must not select a range of tracks")
        precondition(router.handle(event(.shift)) && bypass == 1 && removed == 0)
        precondition(router.handle(event(.option)) && removed == 1 && bypass == 1)
        precondition(router.handle(event([.shift, .option])) && removed == 2, "Option takes precedence")
        precondition(!router.handlesModifiedLeftClick(event(.shift, x: 200)), "Shift selection elsewhere remains available")
        precondition(router.handle(event([.control, .shift])) && menu == 1, "Control click remains a context menu")
        router.interactionBlocked = true
        precondition(!router.handle(event(.option)) && removed == 2)
        router.interactionBlocked = false
        print("FX_SLOT_OPTION_REMOVE_SHIFT_BYPASS_NORMAL_OPEN_AND_SELECTION_BOUNDARIES_OK")
    }
}
