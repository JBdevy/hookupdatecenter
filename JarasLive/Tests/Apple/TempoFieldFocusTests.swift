import AppKit
let app = NSApplication.shared
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 60, height: 24))
field.stringValue = "4"
private let observer = TempoFieldOutsideClickView(frame: field.frame)
window.contentView!.addSubview(field)
window.contentView!.addSubview(observer)
var dismissed = 0
observer.dismiss = { dismissed += 1 }
func event(_ point: NSPoint, _ type: NSEvent.EventType = .leftMouseDown) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
}
window.makeFirstResponder(field)
field.selectText(nil)
observer.active = true
observer.handle(event(NSPoint(x: 20, y: 20)))
precondition(dismissed == 0, "Click inside must preserve selection")
observer.handle(event(NSPoint(x: 160, y: 80)))
precondition(dismissed == 1 && !observer.active, "Click on blank space must dismiss")
precondition(!(window.firstResponder is NSTextView), "Field editor must resign")
observer.handle(event(NSPoint(x: 160, y: 80)))
precondition(dismissed == 1, "Inactive fields must not handle another click")
window.makeFirstResponder(field)
observer.active = true
observer.handle(event(NSPoint(x: 160, y: 80), .rightMouseDown))
precondition(dismissed == 2, "Right click outside also ends editing")
print("PASS: inside click, blank-space click, inactive field, outside right-click")
