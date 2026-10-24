import AppKit
import SwiftUI

protocol TimelineGridKeyboardTarget {}
enum RegionShortcutView {
    static func envelopeOwnsEditingKey(_ event: NSEvent) -> Bool { false }
    static func handleSelectedObjectsDelete(_ event: NSEvent) -> Bool { false }
}
final class ControlMappings {
    static let shared = ControlMappings()
    var editing: Int?
    func handleKey(_ event: NSEvent) -> Bool { false }
}
final class PlaylistSelectionNotice {
    static let shared = PlaylistSelectionNotice()
    func present(_ name: String, in window: NSWindow) {}
}
enum EditorSelectionArea { enum Scope { case setlist } }
final class EditorSelectionRouter {
 static let shared = EditorSelectionRouter()
 func activate(_ scope: EditorSelectionArea.Scope, in window: NSWindow) {}
 func activeScope(in window: NSWindow?) -> EditorSelectionArea.Scope? { nil }
}
// INSERT_SEARCH_KEYS

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(1) }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular); app.finishLaunching()
    let window = NSWindow(contentRect: NSRect(x: 150, y: 300, width: 400, height: 240),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
    window.contentView = host
    let keys = SetlistKeyView(frame: host.bounds); host.addSubview(keys)
    let popup = NSPopover(); popup.behavior = .transient
    let panel = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 120))
    let field = NSTextField(frame: NSRect(x: 10, y: 60, width: 260, height: 28))
    panel.addSubview(field)
    let controller = NSViewController(); controller.view = panel; popup.contentViewController = controller
    var opened = 0, closed = 0
    keys.search = {
        if popup.isShown { closed += 1; keys.searching = false; popup.performClose(nil) }
        else {
            opened += 1; keys.searching = true
            popup.show(relativeTo: NSRect(x: 120, y: 130, width: 30, height: 30), of: host, preferredEdge: .maxY)
            field.window?.makeKey(); field.window?.makeFirstResponder(field)
        }
        return true
    }
    window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
    func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let event = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) { app.sendEvent(event) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.001)); app.updateWindows()
        }
    }
    func tab(flags: CGEventFlags = []) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: down)!
            event.flags = flags; event.post(tap: .cghidEventTap)
        }
        pump(0.8)
    }
    pump(0.5); tab()
    require(popup.isShown && field.currentEditor() != nil && opened == 1, "First Tab must open search and focus typing")
    field.stringValue = "Escudo"
    tab()
    require(!popup.isShown && closed == 1, "Tab must close search while its text field is focused")
    pump(0.3); tab()
    require(popup.isShown && opened == 2, "Next Tab must reopen search without another mouse click")
    tab(flags: .maskShift)
    require(popup.isShown && closed == 1, "Shift-Tab must retain ordinary focus navigation")
    tab()
    require(!popup.isShown && closed == 2, "Plain Tab must close search after focus navigation too")
    print("SETLIST_TAB_OPEN_CLOSE_REOPEN_WITH_FOCUSED_TEXT_OK")
    window.close()
}
