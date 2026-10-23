import AppKit
@MainActor final class SelectionTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}
@main struct EditorSelectionFocusTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let window = SelectionTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600)); window.contentView = root
        var grid = 0, tracks = 0, setlist = 0
        func area(_ frame: NSRect, _ scope: EditorSelectionArea.Scope, _ callback: @escaping () -> Bool) -> EditorSelectionAreaView {
            let view = EditorSelectionAreaView(frame: frame); view.scope = scope; view.selectAll = callback
            root.addSubview(view); return view
        }
        let gridArea = area(NSRect(x: 0, y: 0, width: 800, height: 600), .grid) { grid += 1; return true }
        let tracksArea = area(NSRect(x: 0, y: 0, width: 200, height: 600), .tracks) { tracks += 1; return true }
        let setlistArea = area(NSRect(x: 800, y: 0, width: 200, height: 600), .setlist) { setlist += 1; return true }
        let router = EditorSelectionRouter.shared
        func click(_ x: CGFloat) {
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: x, y: 200), modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            router.handlePointer(event)
        }
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 2, windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        click(400); precondition(router.selectAll(key)); precondition(grid == 1 && tracks == 0)
        click(100); precondition(router.selectAll(key)); precondition(grid == 1 && tracks == 1)
        click(900); precondition(router.selectAll(key)); precondition(grid == 1 && tracks == 1 && setlist == 1)
        click(400); precondition(router.selectAll(key)); precondition(grid == 2 && setlist == 1)
        var steps = 0
        gridArea.moveCursor = { steps += $0; return true }
        let right = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 2,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: true, keyCode: 124)!
        precondition(router.moveCursor(right) && steps == 1)
        click(100); precondition(!router.moveCursor(right) && steps == 1)
        click(400)
        NativeTimelineInputGate.shared.blocked = true; precondition(!router.moveCursor(right))
        NativeTimelineInputGate.shared.blocked = false
        NativeTimelineInputGate.shared.blocked = true; precondition(!router.selectAll(key))
        NativeTimelineInputGate.shared.blocked = false
        let text = NSTextView(frame: NSRect(x: 10, y: 10, width: 100, height: 50)); root.addSubview(text)
        precondition(window.makeFirstResponder(text)); precondition(!router.selectAll(key))
        _ = window.makeFirstResponder(nil)
        gridArea.isHidden = true; precondition(!router.selectAll(key))
        gridArea.isHidden = false
        let detached = SelectionTestWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let bar = EditorSelectionAreaView(frame: NSRect(x: 0, y: 0, width: 300, height: 200)); bar.scope = .tracks; bar.selectAll = { tracks += 1; return true }; detached.contentView = bar
        router.handlePointer(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 100, y: 100), modifierFlags: [], timestamp: 3, windowNumber: detached.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!)
        let detachedKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 4, windowNumber: detached.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        precondition(router.selectAll(detachedKey)); precondition(tracks == 2 && grid == 2 && setlist == 1)
        withExtendedLifetime([gridArea, tracksArea, setlistArea, bar, window, detached]) {}
        print("PASS Command-A follows grid, tracks and setlist focus; preserves text editing; blocks modal input; supports detached mixer")
    }
}
