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
    private var placementKey: String?
    private var placementObservers: [NSObjectProtocol] = []
    private static weak var lastFocusedTool: NSWindow?
    private var orderingObserver: NSObjectProtocol?
    private var orderingMonitor: Any?
    private static func clicked(_ window: NSWindow) {
        guard let main = NSApp.windows.first(where: { !($0 is ProjectionWindow) && $0.title == "CatLive" }) else { return }
        if window === main {
            // Independent editors/configuration panels must not be buried by
            // the main window's owned projection/FX group when resuming edits.
            DispatchQueue.main.async {
                if let tool = lastFocusedTool, tool.isVisible, tool.parent == nil, tool !== main {
                    tool.orderFront(nil)
                }
            }
            return
        }
        lastFocusedTool = window
        var top = window
        while let parent = top.parent, parent !== main { top = parent }
        if top.parent === main, main.childWindows?.last !== top {
            main.removeChildWindow(top); main.addChildWindow(top, ordered: .above)
        }
    }
    func followApplicationWindowOrder() {
        level = .normal
        hidesOnDeactivate = false
        if let main = NSApp.windows.first(where: { !($0 is ProjectionWindow) && $0.title == "CatLive" }) {
            main.addChildWindow(self, ordered: .above)
        }
        guard orderingObserver == nil else { return }
        orderingObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { notice in
            if let window = notice.object as? NSWindow { Self.clicked(window) }
        }
        orderingMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            if let window = event.window { Self.clicked(window) }
            return event
        }
    }
    private var changingPresentation = false
    private func savePlacement() {
        guard !changingPresentation, !inLiveResize, let placementKey else { return }
        UserDefaults.standard.set(NSStringFromRect(saved?.frame ?? frame), forKey: placementKey + ".frame")
        UserDefaults.standard.set(isProjectionFullscreen, forKey: placementKey + ".fullscreen")
        UserDefaults.standard.set(NSStringFromRect(screen?.frame ?? frame), forKey: placementKey + ".screen")
    }
    func restorePlacement(key: String) {
        placementKey = key
        changingPresentation = true
        if let value = UserDefaults.standard.string(forKey: key + ".frame") {
            var rect = NSRectFromString(value)
            if rect.width.isFinite, rect.height.isFinite, rect.minX.isFinite, rect.minY.isFinite, rect.width >= 320, rect.height >= 180 {
                let target = NSScreen.screens.max { a, b in
                    let ar = a.frame.intersection(rect), br = b.frame.intersection(rect)
                    return (ar.isNull ? 0 : ar.width * ar.height) < (br.isNull ? 0 : br.width * br.height)
                }
                let visible = target.flatMap { $0.frame.intersects(rect) ? $0.visibleFrame : nil } ?? NSScreen.main!.visibleFrame
                rect.size.width = min(rect.width, visible.width); rect.size.height = min(rect.height, visible.height)
                rect.origin.x = min(max(rect.minX, visible.minX), visible.maxX - rect.width)
                rect.origin.y = min(max(rect.minY, visible.minY), visible.maxY - rect.height)
                setFrame(rect, display: false)
            } else { center() }
        } else { center() }
        changingPresentation = false
        if UserDefaults.standard.bool(forKey: key + ".fullscreen") {
            let savedScreen = UserDefaults.standard.string(forKey: key + ".screen").map(NSRectFromString)
            toggleProjectionFullscreen(on: NSScreen.screens.first { $0.frame == savedScreen })
        }
        placementObservers = [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                              NSWindow.didEndLiveResizeNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: self, queue: .main) { [weak self] _ in self?.savePlacement() }
        }
    }
    deinit {
        placementObservers.forEach(NotificationCenter.default.removeObserver)
        if let orderingObserver { NotificationCenter.default.removeObserver(orderingObserver) }
        if let orderingMonitor { NSEvent.removeMonitor(orderingMonitor) }
    }

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
        let wasChanging = changingPresentation
        changingPresentation = true
        defer { changingPresentation = wasChanging; savePlacement() }
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
        level = .normal
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(display.frame, display: true, animate: false)
        makeKeyAndOrderFront(nil)
    }
    override func close() {
        savePlacement()
        changingPresentation = true
        if isProjectionFullscreen { toggleProjectionFullscreen() }
        parent?.removeChildWindow(self)
        super.close()
    }
}
#endif
