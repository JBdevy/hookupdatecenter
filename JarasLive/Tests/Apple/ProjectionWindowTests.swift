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
let retainedContent = output.contentView
let retainedWindowNumber = output.windowNumber
for screen in NSScreen.screens {
    output.toggleProjectionFullscreen(on: screen)
    precondition(output.isProjectionFullscreen && output.frame == screen.frame, "presentation fills only the requested display")
    precondition(output.styleMask == .borderless && output.canBecomeKey && !output.hasShadow)
    precondition(application.presentationOptions.contains([.hideDock, .hideMenuBar]), "fullscreen hides the system menu and Dock without using an always-on-top window")
    precondition(main.frame == mainFrame && main.styleMask == mainStyle, "presentation never resizes or moves the main interface")
    output.toggleProjectionFullscreen()
    precondition(output.contentView === retainedContent && output.windowNumber == retainedWindowNumber, "fullscreen transitions retain the native window and rendered content")
    precondition(application.presentationOptions == presentation, "leaving fullscreen restores system chrome")
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

// Exercise native z-order, including a fullscreen projection and three peers.
main.title = "CatLive"
let tools = NSWindow(contentRect: mainFrame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
tools.isReleasedWhenClosed = false; tools.title = "FX"
let projections = (0..<3).map { _ in
    let w = ProjectionWindow(contentRect: originalFrame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false; w.followApplicationWindowOrder(); return w
}
func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
func activate(_ window: NSWindow) {
    window.makeKeyAndOrderFront(nil)
    // Command-line AppKit tests are not the frontmost application. Deliver the
    // native focus notification explicitly, then inspect real WindowServer order.
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    pump()
}
func front(_ a: NSWindow, _ b: NSWindow) -> Bool {
    let ids = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { $0[kCGWindowNumber as String] as? Int }
    guard let x = ids.firstIndex(of: a.windowNumber), let y = ids.firstIndex(of: b.windowNumber) else { return false }
    return x < y
}
activate(main)
for w in projections { activate(w) }
precondition(projections.allSatisfy { $0.parent == nil }, "projections are independent windows, not attached children")
let projectionFrames = projections.map(\.frame)
main.setFrameOrigin(NSPoint(x: main.frame.minX + 100, y: main.frame.minY + 70)); pump()
precondition(projections.map(\.frame) == projectionFrames, "moving the workspace must not move video or teleprompters")
for screen in NSScreen.screens {
    projections[0].setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.minY + 20))
    let placed = projections[0].frame
    activate(main)
    precondition(projections[0].isVisible && projections[0].frame == placed && projections[0].parent == nil,
                 "projection keeps its independent placement when the workspace is activated on another display")
}

ProjectionWindow.followWorkspaceWindow(tools)
activate(tools); pump()
precondition(projections.allSatisfy { front(tools, $0) }, "FX opened last stays above video and both teleprompters")
activate(projections[0]); pump()
precondition(front(projections[0], tools), "clicking a projection raises it normally")
activate(tools); pump()
activate(main)
NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: main); pump()
precondition(projections.allSatisfy { front($0, main) && front(tools, $0) }, "main stays below projections without raising them over FX")
// Cocoa may order the workspace after mouse-up, after our pointer monitor.
main.orderFront(nil); pump()
precondition(projections.allSatisfy { front($0, main) }, "Mouse-up ordering cannot cover projection windows")
NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
precondition(projections.allSatisfy { $0.level == .normal }, "Inactive app does not pin projections above other apps")
NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
precondition(projections.allSatisfy { $0.level == ProjectionWindow.workspaceToolLevel }, "Activation restores in-app tool ordering")
// Simulate a grid event consumed before the general local monitor runs.
main.orderFront(nil)
NotificationCenter.default.post(name: Notification.Name("catlive.workspacePointerDown"), object: main)
pump()
precondition(projections.allSatisfy { front($0, main) && !$0.isMiniaturized },
             "Consumed grid clicks keep video and both teleprompters above the workspace")
projections[1].toggleProjectionFullscreen(); activate(tools); pump()
precondition(projections[1].level == tools.level && front(tools, projections[1]), "fullscreen does not pin video over editing windows")
main.removeChildWindow(tools); activate(tools); activate(main)
precondition(projections.allSatisfy { front(tools, $0) }, "independent configuration windows retain priority after clicking the main workspace")
projections[2].toggleProjectionFullscreen()
projections[1].close()
precondition(application.presentationOptions.contains([.hideDock, .hideMenuBar]), "closing one projection keeps chrome hidden while another is fullscreen")
projections.forEach { $0.close() }; tools.close(); main.close()
precondition(application.presentationOptions == presentation, "closing the last fullscreen projection restores presentation options")
print("PROJECTION_LAST_CLICKED_WINDOW_ORDER_OK")
