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

let key = "jaras.test.projection." + UUID().uuidString
func restoredWindow() -> ProjectionWindow {
    let w = ProjectionWindow(contentRect: NSRect(x: 0,y: 0,width: 640,height: 360),styleMask: [.titled,.closable,.resizable],backing: .buffered,defer: false)
    w.isReleasedWhenClosed = false
    w.restorePlacement(key: key)
    return w
}
let first = restoredWindow()
let targetScreen = NSScreen.screens.last!
let smallFrame = NSRect(x: targetScreen.visibleFrame.minX + 30,y: targetScreen.visibleFrame.minY + 30,width: 650,height: 400)
first.setFrame(smallFrame, display: false)
first.toggleProjectionFullscreen(on: targetScreen)
first.close()
let second = restoredWindow()
precondition(second.isProjectionFullscreen && second.frame == targetScreen.frame, "fullscreen restores on the previous monitor")
second.toggleProjectionFullscreen()
precondition(second.frame == smallFrame, "leaving restored fullscreen restores the previous window dimensions")
second.close()
let third = restoredWindow()
precondition(!third.isProjectionFullscreen && third.frame == smallFrame, "windowed geometry persists independently")
third.close()
for suffix in [".frame", ".fullscreen", ".screen"] { UserDefaults.standard.removeObject(forKey: key + suffix) }
print("PROJECTION_PERSISTENT_MONITOR_FRAME_AND_FULLSCREEN_OK")
