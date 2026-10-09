import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular); app.finishLaunching()
let suite = "jaras.timer.ui-test." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
var clock = 100.0
let timer = TeleprompterTimerController(defaults: defaults, now: { clock })
let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 140,height: 40),styleMask: [.titled],backing: .buffered,defer: false)
window.isReleasedWhenClosed = false
let host = NSHostingView(rootView: TeleprompterTimerControl(timer: timer))
window.contentView = host; window.orderFront(nil); host.layoutSubtreeIfNeeded()
func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.07)) }
func fields(in view: NSView) -> [NSTextField] {
    if let control = view as? NSTextField, control.isEditable { return [control] }
    return view.subviews.flatMap { fields(in: $0) }
}
settle()
precondition(fields(in: host).count == 3, "hours, minutes and seconds are separate native inputs")
let input = fields(in: host)[1]
input.selectText(nil); settle()
guard let editor = input.currentEditor() as? NSTextView else { fatalError("timer field can receive the keyboard") }
precondition(window.firstResponder is NSTextView, "global transport shortcuts see a text responder and leave Enter/Space to the input")
editor.insertText("02", replacementRange: NSRange(location: 0,length: (editor.string as NSString).length)); settle()
precondition(timer.mode == .countdown && timer.targetSeconds == 0, "typing remains a draft")
func key(_ code: UInt16) {
    let text = code == 53 ? "\u{1b}" : "\r"
    editor.keyDown(with: NSEvent.keyEvent(with: .keyDown,location: .zero,modifierFlags: [],timestamp: ProcessInfo.processInfo.systemUptime,windowNumber: window.windowNumber,context: nil,characters: text,charactersIgnoringModifiers: text,isARepeat: false,keyCode: code)!)
    settle()
}
key(36)
precondition(timer.mode == .countdown && timer.targetSeconds == 120 && !timer.running, "Enter applies the duration without playing audio or starting the timer")
timer.start(); settle()
precondition(timer.running && timer.displayText() == "00:02:00", "the toolbar observes the independent timer state")
precondition(fields(in: host).isEmpty, "a running timer shows the live count instead of an editable target")
func displayedText(_ view: NSView) -> [String] {
    if let field = view as? NSTextField { return [field.stringValue] }
    return view.subviews.flatMap { displayedText($0) }
}
func nativeButtons(_ view: NSView) -> [NSButton] {
    (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(nativeButtons)
}
func press(_ title: String, in object: Any) {
    if let sheet = object as? NSWindow, let content = sheet.contentView,
       let button = nativeButtons(content).first(where: { $0.title == title }) {
        let parent = sheet.sheetParent
        button.performClick(nil)
        for _ in 0..<25 { settle(); if parent?.attachedSheet == nil { break } }
        return
    }
    guard let view = object as? NSView, let window = view.window else { fatalError("Missing button container") }
    let toolbar = title == "Timer Stop" || title == "Timer Play"
    let local = NSPoint(x: toolbar ? view.bounds.maxX - 30 : 45,
                        y: toolbar ? view.bounds.midY : view.isFlipped ? view.bounds.maxY - 30 : view.bounds.minY + 30)
    let point = view.convert(local, to: nil)
    func event(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    NSApp.postEvent(event(.leftMouseUp), atStart: false)
    window.sendEvent(event(.leftMouseDown))
    if let up = NSApp.nextEvent(matching: .leftMouseUp, until: Date(timeIntervalSinceNow: 0.01), inMode: .default, dequeue: true) { window.sendEvent(up) }
    settle()
}

clock = 219
RunLoop.main.run(until: Date().addingTimeInterval(0.65))
FileHandle.standardError.write(Data("VISIBLE_TIMER_VALUES \(displayedText(host))\n".utf8))
precondition(displayedText(host).contains("01"), "the visible seconds field updates while the timer runs")
precondition(timer.displayText() == "00:00:01" && !timer.expired())
clock = 220
precondition(timer.displayText() == "00:00:00" && timer.expired())
let bright = timer.displayOpacity()
clock = 220.5
precondition(timer.displayOpacity() != bright, "expired timer blinks")
precondition(!timer.setTargetText("00:09:00") && timer.targetSeconds == 120, "running timer cannot be edited through configuration")
clock = 221
RunLoop.main.run(until: Date().addingTimeInterval(0.65))
precondition(displayedText(host).contains("−00"), "the visible hours field gains the negative sign")
precondition(timer.displayText() == "−00:00:01", "timer continues below zero")
clock = 282
precondition(timer.displayText() == "−00:01:02", "negative minutes continue counting")
window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true); settle()
let pendingRun = timer.runID
press("Timer Stop", in: host)
precondition(timer.running && timer.runID == pendingRun, "opening Stop confirmation keeps the timer running")
guard let firstAlert = window.attachedSheet else { fatalError("toolbar Stop must present a confirmation") }
press("Cancel", in: firstAlert)
precondition(timer.running && timer.runID == pendingRun, "Cancel leaves the timer and current run untouched")
press("Timer Stop", in: host)
guard let stopAlert = window.attachedSheet else { fatalError("toolbar confirmation can be reopened") }
press("Stop timer", in: stopAlert)
precondition(timer.displayText() == "00:00:00" && timer.targetText == "00:02:00", "Stop resets the independent clock and retains its target")
precondition(fields(in: host).map(\.stringValue) == ["00","02","00"], "Stop restores the editable target fields")
press("Timer Play", in: host)
precondition(timer.running && window.attachedSheet == nil, "Start runs immediately without confirmation")
let staleRun = timer.runID
press("Timer Stop", in: host)
timer.stopAndReset(); timer.start(); settle()
precondition(timer.running && timer.runID != staleRun && !timer.stopAndReset(ifRunID: staleRun),
             "a pending confirmation cannot stop a timer restarted elsewhere")
timer.stopAndReset(); settle()
let reopened = TeleprompterTimerController(defaults: defaults, now: { clock })
precondition(reopened.mode == .countdown && reopened.targetSeconds == 120)
window.close()
let configurationWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 405), styleMask: [.titled], backing: .buffered, defer: false)
configurationWindow.isReleasedWhenClosed = false
let configuration = NSHostingView(rootView: TeleprompterTimerConfiguration(controller: timer, close: {}))
configurationWindow.contentView = configuration; configurationWindow.makeKeyAndOrderFront(nil); settle()
press("Start", in: configuration)
precondition(timer.running && configurationWindow.attachedSheet == nil, "configuration Start is immediate")
press("Stop", in: configuration)
guard let configurationCancel = configurationWindow.attachedSheet else { fatalError("configuration Stop asks for confirmation") }
precondition(timer.running)
press("Cancel", in: configurationCancel)
precondition(timer.running, "configuration Cancel keeps running")
press("Stop", in: configuration)
guard let configurationStop = configurationWindow.attachedSheet else { fatalError("configuration Stop confirmation can reopen") }
press("Stop timer", in: configurationStop)
precondition(!timer.running && timer.displayText() == "00:00:00", "configuration confirmation performs existing Stop/reset")
configurationWindow.close()
print("TIMER_TOOLBAR_CONFIGURATION_START_IMMEDIATE_STOP_CONFIRM_CANCEL_STALE_RUN_AND_RESET_OK")
