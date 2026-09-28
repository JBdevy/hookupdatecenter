import AppKit

let app = NSApplication.shared
for maximumLength in [400, 30] {
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 466, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
var committed: [String] = [], closes = 0
let host = NSHostingView(rootView: TextItemEditor(text: "", maximumLength: maximumLength, apply: { committed.append($0); return true }, close: { closes += 1 }))
window.contentView = host
host.layoutSubtreeIfNeeded()
func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
func textView(in view: NSView) -> NSTextView? {
    if let editor = view as? NSTextView { return editor }
    return view.subviews.lazy.compactMap { textView(in: $0) }.first
}
settle()
guard let editor = textView(in: host) else { fatalError("The floating editor must contain a real notepad") }
precondition(window.firstResponder === editor, "the notepad receives focus immediately")
precondition(editor.bounds.width > 100, "the text container follows the available editor width")
let maximum = String(repeating: "🎵", count: maximumLength)
editor.insertText(maximum, replacementRange: NSRange(location: 0, length: 0)); settle()
precondition(editor.string == maximum && committed.isEmpty, "Unicode text remains a local draft until Apply")
editor.insertText("é", replacementRange: NSRange(location: (maximum as NSString).length, length: 0)); settle()
precondition(editor.string == maximum, "the first character above this track's limit cannot enter the draft")
editor.insertText(String(repeating: "x", count: maximumLength + 1), replacementRange: NSRange(location: 0, length: (editor.string as NSString).length)); settle()
precondition(editor.string == maximum, "a paste beyond the limit is rejected without deleting existing text")
editor.insertText("Am", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length)); settle()
func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) {
    let value = code == 53 ? "\u{1b}" : "\r"
    editor.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: value, charactersIgnoringModifiers: value, isARepeat: false, keyCode: code)!)
    settle()
}
key(36)
precondition(editor.string == "Am\n" && committed.isEmpty, "Enter inserts a new line and never commits a multiline draft")
editor.insertText("G", replacementRange: NSRange(location: (editor.string as NSString).length, length: 0)); settle()
key(36, flags: .command)
precondition(committed == ["Am\nG"] && closes == 1, "Command+Enter confirms the full draft once")
editor.insertText(" change", replacementRange: NSRange(location: (editor.string as NSString).length, length: 0)); settle()
key(53)
precondition(committed == ["Am\nG"] && closes == 2, "Escape cancels without another project edit")
window.close()
}
print("TEXT_NOTEPAD_TP400_CHORDS30_LIMIT_PASTE_FOCUS_MULTILINE_APPLY_AND_CANCEL_OK")
