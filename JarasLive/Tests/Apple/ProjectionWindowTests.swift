import AppKit

let application = NSApplication.shared
let main = NSWindow(contentRect: NSRect(x: 90,y: 90,width: 700,height: 420), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
main.isReleasedWhenClosed = false
let mainFrame = main.frame, mainStyle = main.styleMask, presentation = application.presentationOptions
let output = ProjectionWindow(contentRect: NSRect(x: 180,y: 180,width: 640,height: 360), styleMask: [.titled,.closable,.resizable,.miniaturizable], backing: .buffered, defer: false)
output.isReleasedWhenClosed = false; output.contentView = NSView(frame: NSRect(x: 0,y: 0,width: 640,height: 360))
let originalFrame = output.frame, originalStyle = output.styleMask, originalLevel = output.level, originalBehavior = output.collectionBehavior
func click(_ type: NSEvent.EventType, count: Int) {
    output.sendEvent(NSEvent.mouseEvent(with: type,location: NSPoint(x: 100,y: 100),modifierFlags: [],timestamp: ProcessInfo.processInfo.systemUptime,windowNumber: output.windowNumber,context: nil,eventNumber: 1,clickCount: count,pressure: 1)!)
}
for screen in NSScreen.screens {
    output.toggleProjectionFullscreen(on: screen)
    precondition(output.isProjectionFullscreen && output.frame == screen.frame, "presentation fills only the requested display")
    precondition(output.styleMask == .borderless && output.canBecomeKey && !output.hasShadow)
    precondition(application.presentationOptions == presentation && main.frame == mainFrame && main.styleMask == mainStyle, "second-display presentation never changes the main interface or application menu/Dock visibility")
    output.toggleProjectionFullscreen()
    precondition(!output.isProjectionFullscreen && output.frame == originalFrame && output.styleMask == originalStyle && output.level == originalLevel && output.collectionBehavior == originalBehavior)
}
click(.leftMouseDown,count: 2)
precondition(output.isProjectionFullscreen,"left double click enters presentation mode")
output.sendEvent(NSEvent.keyEvent(with: .keyDown,location: .zero,modifierFlags: [],timestamp: ProcessInfo.processInfo.systemUptime,windowNumber: output.windowNumber,context: nil,characters: "\u{1b}",charactersIgnoringModifiers: "\u{1b}",isARepeat: false,keyCode: 53)!)
precondition(!output.isProjectionFullscreen,"Escape restores the independent window")
click(.leftMouseDown,count: 2); click(.leftMouseDown,count: 2)
precondition(!output.isProjectionFullscreen,"a second left double click restores window mode")
output.closesOnRightDoubleClick = true
click(.leftMouseDown,count: 2); click(.rightMouseDown,count: 2)
precondition(!output.isVisible && !output.isProjectionFullscreen,"video right double click closes and releases presentation mode")
precondition(application.presentationOptions == presentation && main.frame == mainFrame)
main.close()
print("PROJECTION_DOUBLE_CLICK_ESCAPE_RESTORE_AND_INDEPENDENT_DISPLAY_OK")
