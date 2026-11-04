import AppKit

enum FixtureKeyMonitors {
    static var handlers: [(UUID, (NSEvent) -> NSEvent?)] = []
    static func addLocalMonitorForEvents(matching: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) -> Any? {
        let token = UUID(); handlers.append((token, handler)); return token
    }
    static func removeMonitor(_ token: Any) { handlers.removeAll { $0.0 == token as? UUID } }
    static func send(_ event: NSEvent) {
        var next: NSEvent? = event
        for (_, handler) in handlers { guard let value = next else { break }; next = handler(value) }
    }
}

final class ClipboardTestApplication: NSApplication {
    var targetWindow: NSWindow?
    var forwarded: [String] = []
    override var keyWindow: NSWindow? { targetWindow }
    override func sendAction(_ action: Selector, to target: Any?, from sender: Any?) -> Bool {
        forwarded.append(NSStringFromSelector(action)); return true
    }
}
final class ClipboardTestWindow: NSWindow { override var isKeyWindow: Bool { true } }
final class AutomationLaneView: NSView {}
final class ControlMappings {
    static let shared = ControlMappings()
    var editing: String?
    func handleKey(_ event: NSEvent) -> Bool { false }
}
final class NativeTimelineInputGate {
    static let shared = NativeTimelineInputGate()
    var blocked = false
    func isBlocked(_ window: NSWindow?) -> Bool { blocked }
    func cancelActiveResize(for window: NSWindow?) -> Bool { false }
}
enum SetlistKeyView { static func ownsDelete(_ event: NSEvent) -> Bool { false }; static func handleDelete(_ event: NSEvent) -> Bool { false } }

let app = ClipboardTestApplication.shared as! ClipboardTestApplication
let first = ClipboardTestWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
let second = ClipboardTestWindow(contentRect: first.frame, styleMask: [.titled], backing: .buffered, defer: false)
let owner = RegionShortcutView(), other = RegionShortcutView()
first.contentView!.addSubview(owner); second.contentView!.addSubview(other)
var pasted = 0, copied = 0, cut = 0, otherPaste = 0, duplicated = 0
owner.duplicateItems = { duplicated += 1 }
owner.pasteItems = { pasted += 1 }; other.pasteItems = { otherPaste += 1 }
owner.copyItems = { copied += 1; return true }; owner.moveItems = { cut += 1; return true }
app.targetWindow = first
for _ in 0..<10 { RegionShortcutView.performClipboard("v") }
RegionShortcutView.performClipboard("c"); RegionShortcutView.performClipboard("x")
RegionShortcutView.performClipboard("d"); precondition(duplicated == 1)
precondition(pasted == 10 && copied == 1 && cut == 1 && otherPaste == 0)
app.targetWindow = second; RegionShortcutView.performClipboard("v")
precondition(otherPaste == 1 && pasted == 10)
app.targetWindow = first
let text = NSTextView(frame: .init(x: 0, y: 0, width: 100, height: 40)); first.contentView!.addSubview(text)
precondition(first.makeFirstResponder(text))
RegionShortcutView.performClipboard("v")
precondition(app.forwarded == ["paste:"] && pasted == 10, "text keeps native paste")
RegionShortcutView.performClipboard("d"); precondition(duplicated == 1, "text editing must not duplicate timeline items")
first.makeFirstResponder(nil)
NativeTimelineInputGate.shared.blocked = true; RegionShortcutView.performClipboard("v")
precondition(pasted == 10, "modal grid gates remain respected")
NativeTimelineInputGate.shared.blocked = false
owner.removeFromSuperview(); RegionShortcutView.performClipboard("v")
precondition(pasted == 10, "detached editors cannot receive paste")
// Cached tab views stay attached to the SAME window. Their local key monitors
// must pass the event on, regardless of monitor registration order.
let oldTab = NSView(frame: first.contentView!.bounds), newTab = NSView(frame: first.contentView!.bounds)
first.contentView!.addSubview(oldTab); first.contentView!.addSubview(newTab)
let oldOwner = RegionShortcutView(), newOwner = RegionShortcutView()
oldTab.addSubview(oldOwner); newTab.addSubview(newOwner)
var oldCommands = 0, newCommands = 0
for view in [oldOwner, newOwner] {
    let count = { if view === oldOwner { oldCommands += 1 } else { newCommands += 1 } }
    view.copyItems = { count(); return true }; view.moveItems = { count(); return true }
    view.pasteItems = count; view.duplicateItems = count
}
oldTab.isHidden = true
func keys() {
    for (key, code) in [("c", UInt16(8)), ("x", 7), ("v", 9), ("d", 2)] {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: first.windowNumber, context: nil, characters: key,
            charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
        FixtureKeyMonitors.send(event)
    }
}
keys()
precondition(oldCommands == 0 && newCommands == 4, "Hidden tabs must never consume clipboard shortcuts")
// Also reject an inactive tab during the frame before AppKit hides its host.
oldTab.isHidden = false; oldOwner.isCurrentProject = { false }
keys(); RegionShortcutView.performClipboard("v")
precondition(oldCommands == 0 && newCommands == 9, "Clipboard commands must reach only the foreground project")
print("CACHED_PROJECT_TABS_CLIPBOARD_SHORTCUTS_ONLY_EDIT_FOREGROUND_PROJECT_OK")
print("GRID_CLIPBOARD_MENU_FOCUS_WINDOW_AND_MODAL_ROUTING_OK")
