@MainActor func runHistoryShortcutTests() {
let app = NSApplication.shared
let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
let other = NSWindow(contentRect: panel.frame, styleMask: [.titled], backing: .buffered, defer: false)
var undos = 0, redos = 0
func key(_ flags: NSEvent.ModifierFlags, window: NSWindow? = nil, repeating: Bool = false) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: (window ?? panel).windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z",
        isARepeat: repeating, keyCode: 6)!
}
@MainActor func handle(_ event: NSEvent) -> Bool {
    FXHistoryShortcut.handle(event, in: panel, undo: { undos += 1 }, redo: { redos += 1 })
}
precondition(handle(key(.command)) && undos == 1)
precondition(handle(key(.control)) && undos == 2)
precondition(handle(key([.command, .shift])) && redos == 1)
precondition(handle(key([.control, .shift])) && redos == 2)
precondition(handle(key(.command, repeating: true)) && undos == 2)
precondition(!handle(key(.command, window: other)) && undos == 2)
precondition(!handle(key([.command, .option])) && undos == 2)
let text = NSTextView(frame: panel.contentView!.bounds)
panel.contentView!.addSubview(text); panel.makeFirstResponder(text)
precondition(!handle(key(.command)) && undos == 2, "Text editing must retain its own undo")
panel.makeFirstResponder(panel)
precondition(handle(key(.command)) && undos == 3)
print("FX_WINDOW_CMD_CTRL_UNDO_REDO_TEXT_FOCUS_AND_OTHER_WINDOW_OK")
_ = app
}
MainActor.assumeIsolated { runHistoryShortcutTests() }
