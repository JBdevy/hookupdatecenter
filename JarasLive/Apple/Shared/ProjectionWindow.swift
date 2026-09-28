#if os(macOS)
import AppKit
import CoreGraphics

/// A presentation belongs to one display. Never change application-wide menu
/// or Dock visibility when showing it on a second monitor.
final class ProjectionWindow: NSWindow {
    var closesOnRightDoubleClick = false
    private(set) var isProjectionFullscreen = false
    private struct SavedState {
        let frame: NSRect
        let style: NSWindow.StyleMask
        let behavior: NSWindow.CollectionBehavior
        let level: NSWindow.Level
        let title: NSWindow.TitleVisibility
        let transparentTitlebar: Bool
        let movable: Bool
        let movableByBackground: Bool
        let shadow: Bool
        let canHide: Bool
        let hidesOnDeactivate: Bool
    }
    private var saved: SavedState?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { !isProjectionFullscreen }
    override func sendEvent(_ event: NSEvent) {
        if (event.type == .leftMouseDown || event.type == .rightMouseDown), event.clickCount == 2, let contentView,
           contentView.bounds.contains(contentView.convert(event.locationInWindow, from: nil)) {
            if event.type == .leftMouseDown { toggleProjectionFullscreen(); return }
            if event.type == .rightMouseDown && closesOnRightDoubleClick { close(); return }
        }
        if event.type == .keyDown && event.keyCode == 53 && isProjectionFullscreen {
            toggleProjectionFullscreen(); return
        }
        super.sendEvent(event)
    }
    override func toggleFullScreen(_ sender: Any?) { toggleProjectionFullscreen() }
    func toggleProjectionFullscreen(on target: NSScreen? = nil) {
        if let state = saved {
            saved = nil; isProjectionFullscreen = false
            styleMask = state.style; collectionBehavior = state.behavior; level = state.level
            titleVisibility = state.title; titlebarAppearsTransparent = state.transparentTitlebar
            isMovable = state.movable; isMovableByWindowBackground = state.movableByBackground
            hasShadow = state.shadow; canHide = state.canHide; hidesOnDeactivate = state.hidesOnDeactivate
            setFrame(state.frame, display: true, animate: false)
            makeKeyAndOrderFront(nil)
            return
        }
        guard let display = target ?? screen ?? NSScreen.main else { return }
        saved = SavedState(frame: frame, style: styleMask, behavior: collectionBehavior, level: level,
                           title: titleVisibility, transparentTitlebar: titlebarAppearsTransparent,
                           movable: isMovable, movableByBackground: isMovableByWindowBackground,
                           shadow: hasShadow, canHide: canHide, hidesOnDeactivate: hidesOnDeactivate)
        isProjectionFullscreen = true
        styleMask = .borderless; titleVisibility = .hidden; titlebarAppearsTransparent = true
        isMovable = false; isMovableByWindowBackground = false; hasShadow = false
        canHide = false; hidesOnDeactivate = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(display.frame, display: true, animate: false)
        makeKeyAndOrderFront(nil)
    }
    override func close() {
        if isProjectionFullscreen { toggleProjectionFullscreen() }
        super.close()
    }
}
#endif
