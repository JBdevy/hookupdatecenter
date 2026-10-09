import AppKit

final class ClipboardTestApplication: NSApplication {
    var targetWindow: NSWindow?
    var forwarded: [String] = []
    override var keyWindow: NSWindow? { targetWindow }
    override func sendAction(_ action: Selector, to target: Any?, from sender: Any?) -> Bool {
        forwarded.append(NSStringFromSelector(action)); return true
    }
}
final class ClipboardTestWindow: NSWindow { override var isKeyWindow: Bool { true } }
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
enum SetlistKeyView { static func handleDelete(_ event: NSEvent) -> Bool { false } }

let app = ClipboardTestApplication.shared as! ClipboardTestApplication
let first = ClipboardTestWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
let second = ClipboardTestWindow(contentRect: first.frame, styleMask: [.titled], backing: .buffered, defer: false)
let owner = RegionShortcutView(), other = RegionShortcutView()
first.contentView!.addSubview(owner); second.contentView!.addSubview(other)
var pasted = 0, copied = 0, cut = 0, otherPaste = 0
owner.pasteItems = { pasted += 1 }; other.pasteItems = { otherPaste += 1 }
owner.copyItems = { copied += 1; return true }; owner.moveItems = { cut += 1; return true }
app.targetWindow = first
for _ in 0..<10 { RegionShortcutView.performClipboard("v") }
RegionShortcutView.performClipboard("c"); RegionShortcutView.performClipboard("x")
precondition(pasted == 10 && copied == 1 && cut == 1 && otherPaste == 0)
app.targetWindow = second; RegionShortcutView.performClipboard("v")
precondition(otherPaste == 1 && pasted == 10)
app.targetWindow = first
let text = NSTextView(frame: .init(x: 0, y: 0, width: 100, height: 40)); first.contentView!.addSubview(text)
precondition(first.makeFirstResponder(text))
RegionShortcutView.performClipboard("v")
precondition(app.forwarded == ["paste:"] && pasted == 10, "text keeps native paste")
first.makeFirstResponder(nil)
NativeTimelineInputGate.shared.blocked = true; RegionShortcutView.performClipboard("v")
precondition(pasted == 10, "modal grid gates remain respected")
NativeTimelineInputGate.shared.blocked = false
owner.removeFromSuperview(); RegionShortcutView.performClipboard("v")
precondition(pasted == 10, "detached editors cannot receive paste")
print("GRID_CLIPBOARD_MENU_FOCUS_WINDOW_AND_MODAL_ROUTING_OK")
