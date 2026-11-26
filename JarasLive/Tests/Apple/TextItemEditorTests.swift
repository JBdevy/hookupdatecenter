import AppKit

MainActor.assumeIsolated {
let app = NSApplication.shared
app.setActivationPolicy(.regular); app.activate(ignoringOtherApps: true)
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
let main = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
main.title = "CatLive"; main.isReleasedWhenClosed = false; main.makeKeyAndOrderFront(nil)
let projection = ProjectionWindow(contentRect: NSRect(x: 40, y: 40, width: 640, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
projection.isReleasedWhenClosed = false; projection.followApplicationWindowOrder(); projection.makeKeyAndOrderFront(nil)
func inFront(_ a: NSWindow, _ b: NSWindow) -> Bool {
    let ids = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { $0[kCGWindowNumber as String] as? Int }
    guard let x = ids.firstIndex(of: a.windowNumber), let y = ids.firstIndex(of: b.windowNumber) else { return false }
    return x < y
}
for textLength in [10000, 20000] {
let window = makeWorkspacePanel(title: "Text Editor", size: NSSize(width: 700, height: 360), minimum: NSSize(width: 700, height: 360))
window.isReleasedWhenClosed = false
var committed: [String] = [], closes = 0
let host = NSHostingView(rootView: TextItemEditor(text: "", showHeader: false, apply: { committed.append($0); return true }, close: { closes += 1 }))
window.contentView = host
attachWorkspacePanel(window)
window.makeKeyAndOrderFront(nil)
NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
host.layoutSubtreeIfNeeded()
func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
func textView(in view: NSView) -> NSTextView? {
    if let editor = view as? NSTextView { return editor }
    return view.subviews.lazy.compactMap { textView(in: $0) }.first
}
settle()
guard let editor = textView(in: host) else { fatalError("The floating editor must contain a real notepad") }
precondition(projection.isVisible && projection.parent == nil && inFront(projection, main) && inFront(window, projection), "Typing must keep the teleprompter above the workspace and below the independent editor")
precondition(window.firstResponder === editor, "the notepad receives focus immediately")
precondition(editor.bounds.width > 100, "the text container follows the available editor width")
let maximum = String(repeating: "🎵", count: textLength)
editor.insertText(maximum, replacementRange: NSRange(location: 0, length: 0)); settle()
precondition(editor.string == maximum && committed.isEmpty, "Unicode text remains a local draft until Apply")
editor.insertText("é", replacementRange: NSRange(location: (maximum as NSString).length, length: 0)); settle()
precondition(editor.string == maximum + "é", "text above the former limit stays editable")
editor.insertText(String(repeating: "x", count: textLength + 1), replacementRange: NSRange(location: 0, length: (editor.string as NSString).length)); settle()
precondition(editor.string == String(repeating: "x", count: textLength + 1), "long pasted text is preserved without truncation")
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
guard let coloredEditor = editor as? TextItemNotepadView else { fatalError("Missing colour-capable editor") }
coloredEditor.applyTextColor(0xff4040, range: NSRange(location: 0, length: 2))
settle()
precondition(editor.string == "Am\nG" && committed == ["Am\nG"], "Colour must keep visible text unchanged and remain a draft")
precondition(ItemTextColors.runs(coloredEditor.encodedText) == [.init(text: "Am", color: 0xff4040), .init(text: "\nG")], "Only the selected chord gets a colour")
let encoded = coloredEditor.encodedText
coloredEditor.setSelectedRange(NSRange(location: 2, length: 0))
coloredEditor.insertText("7", replacementRange: NSRange(location: NSNotFound, length: 0)); settle()
precondition(ItemTextColors.runs(coloredEditor.encodedText) == [.init(text: "Am", color: 0xff4040), .init(text: "7\nG")], "New typing next to colored text must use the default color")
coloredEditor.setSelectedRange(NSRange(location: 0, length: 2))
coloredEditor.insertText("Dm", replacementRange: NSRange(location: NSNotFound, length: 0)); settle()
precondition(ItemTextColors.runs(coloredEditor.encodedText) == [.init(text: "Dm7\nG")], "Typing over a colored selection must not inherit its color")
coloredEditor.loadColoredText(encoded)
coloredEditor.loadColoredText(encoded)
precondition(coloredEditor.encodedText == encoded && editor.string == "Am\nG", "Reopening must retain colour without exposing storage markup")
editor.insertText(" change", replacementRange: NSRange(location: (editor.string as NSString).length, length: 0)); settle()
key(53)
precondition(committed == ["Am\nG"] && closes == 2, "Escape cancels without another project edit")
window.close()
}
let columnsWindow = makeWorkspacePanel(title: "Text Editor", size: NSSize(width: 700, height: 360), minimum: NSSize(width: 700, height: 360))
columnsWindow.isReleasedWhenClosed = false
var columnCommits: [String] = []
let columnHost = NSHostingView(rootView: TextItemEditor(text: ItemTextColors.encodeColumns(["Primeira", "Segunda"]), showHeader: false, apply: { columnCommits.append($0); return true }, close: {}))
columnsWindow.contentView = columnHost; columnsWindow.makeKeyAndOrderFront(nil)
RunLoop.main.run(until: Date().addingTimeInterval(0.1)); columnHost.layoutSubtreeIfNeeded()
func columnEditors(_ view: NSView) -> [NSTextView] {
    if let editor = view as? NSTextView { return [editor] }
    return view.subviews.flatMap(columnEditors)
}
let bitmap = columnHost.bitmapImageRepForCachingDisplay(in: columnHost.bounds)!
columnHost.cacheDisplay(in: columnHost.bounds, to: bitmap)
if let png = bitmap.representation(using: .png, properties: [:]) { try! png.write(to: URL(fileURLWithPath: "/tmp/catlive124-mac-editor.png")) }
let editors = columnEditors(columnHost)
precondition(editors.count == 2, "Two columns need two independently editable notepads")
precondition(editors.map(\.string) == ["Primeira", "Segunda"], "Reopening must preserve the column assignment")
precondition(editors.allSatisfy { $0.bounds.width > 200 }, "Both editors must fit without horizontal clipping")
editors[1].insertText(" nova", replacementRange: NSRange(location: 7, length: 0))
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
(editors[1] as! TextItemNotepadView).apply()
precondition(columnCommits.count == 1 && ItemTextColors.columns(columnCommits[0]) == ["Primeira", "Segunda nova"], "Editing the second column must not alter the first")
columnsWindow.close()
projection.close(); main.close()
print("TEXT_NOTEPAD_UNLIMITED_PASTE_FOCUS_MULTILINE_APPLY_AND_CANCEL_OK")

}
