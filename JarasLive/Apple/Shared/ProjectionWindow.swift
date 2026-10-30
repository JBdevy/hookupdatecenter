#if os(macOS)
import AppKit
import CoreGraphics
import QuartzCore

/// A presentation fills its display without moving the workspace. System chrome
/// is hidden for this app while a projection is fullscreen and restored afterward.
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
    private static var orderingObserver: NSObjectProtocol?
    private static var orderingMonitor: Any?
    private static var consumedPointerObserver: NSObjectProtocol?
    private static var orderingPending = false
    private static let workspaceTools = NSHashTable<NSWindow>.weakObjects()
    private static let toolLevels = NSMapTable<NSWindow, NSNumber>.weakToStrongObjects()
    private static var activationObservers: [NSObjectProtocol] = []
    static let workspaceToolLevel = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
    private static func updateToolLevels(active: Bool) {
        for window in workspaceTools.allObjects {
            let desired = toolLevels.object(forKey: window)?.intValue ?? workspaceToolLevel.rawValue
            window.level = active ? NSWindow.Level(rawValue: desired) : .normal
        }
    }

    private static func clicked(_ window: NSWindow) {
        guard let main = NSApp.windows.first(where: { !($0 is ProjectionWindow) && $0.isVisible && $0.title == "CatLive" }) else { return }
        guard window === main else {
            lastFocusedTool = window
            return
        }
        guard !orderingPending else { return }
        orderingPending = true
        DispatchQueue.main.async {
            orderingPending = false
            guard main.isVisible else { return }
            // Keep auxiliary windows above the workspace without parenting them:
            // child windows move with their parent and inherit its display/Space.
            let tools = NSApp.orderedWindows.filter {
                $0 !== main && $0.isVisible && $0.level == .normal &&
                    ($0.parent == nil || $0.parent === main)
            }
            var anchor = main.windowNumber
            for tool in tools.reversed() {
                tool.order(.above, relativeTo: anchor)
                anchor = tool.windowNumber
            }
            if let tool = lastFocusedTool, tool.isVisible, tool !== main {
                tool.orderFront(nil)
            }
        }
    }
    func followApplicationWindowOrder() {
        level = .normal
        hidesOnDeactivate = false
        Self.followWorkspaceWindow(self)
    }
    static func followWorkspaceWindow(_ window: NSWindow) {
        window.parent?.removeChildWindow(window)
        workspaceTools.add(window)
        if toolLevels.object(forKey: window) == nil {
            toolLevels.setObject(NSNumber(value: max(window.level.rawValue, workspaceToolLevel.rawValue)), forKey: window)
        }
        window.level = NSWindow.Level(rawValue: toolLevels.object(forKey: window)!.intValue)
        guard orderingObserver == nil else { return }
        // Mouse-up can raise the main window after event monitors run.
        // A dedicated in-app level makes tool ordering independent of that race.
        activationObservers = [
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in updateToolLevels(active: true) },
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in updateToolLevels(active: false) }
        ]
        orderingObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { notice in
            if let window = notice.object as? NSWindow { Self.clicked(window) }
        }
        // Native grid input can consume the event before local monitors see it.
        consumedPointerObserver = NotificationCenter.default.addObserver(forName: Notification.Name("catlive.workspacePointerDown"), object: nil, queue: .main) { notice in
            if let window = notice.object as? NSWindow { Self.clicked(window) }
        }
        orderingMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            if let window = event.window { Self.clicked(window) }
            return event
        }
    }
    private static var savedPresentationOptions: NSApplication.PresentationOptions?
    private static func updatePresentationOptions() {
        let presenting = NSApp.windows.contains { ($0 as? ProjectionWindow)?.isProjectionFullscreen == true }
        if presenting {
            if savedPresentationOptions == nil { savedPresentationOptions = NSApp.presentationOptions }
            var options = savedPresentationOptions ?? []
            options.subtract([.autoHideDock, .autoHideMenuBar])
            options.formUnion([.hideDock, .hideMenuBar])
            NSApp.presentationOptions = options
        } else if let options = savedPresentationOptions {
            NSApp.presentationOptions = options
            savedPresentationOptions = nil
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
        // Publish the final style and frame together, retaining the hosting view
        // and video layer instead of displaying intermediate window geometry.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        defer {
            contentView?.layoutSubtreeIfNeeded()
            if isVisible { contentView?.displayIfNeeded() }
            NSAnimationContext.endGrouping()
            CATransaction.commit()
            changingPresentation = wasChanging
            savePlacement()
        }
        if let state = saved {
            saved = nil; isProjectionFullscreen = false
            Self.updatePresentationOptions()
            styleMask = state.style; collectionBehavior = state.behavior; level = state.level
            titleVisibility = state.title; titlebarAppearsTransparent = state.transparentTitlebar
            isMovable = state.movable; isMovableByWindowBackground = state.movableByBackground
            hasShadow = state.shadow; canHide = state.canHide; hidesOnDeactivate = state.hidesOnDeactivate
            setFrame(state.frame, display: false, animate: false)
            makeKeyAndOrderFront(nil)
            return
        }
        guard let display = target ?? screen ?? NSScreen.main else { return }
        saved = SavedState(frame: frame, style: styleMask, behavior: collectionBehavior, level: level,
                           title: titleVisibility, transparentTitlebar: titlebarAppearsTransparent,
                           movable: isMovable, movableByBackground: isMovableByWindowBackground,
                           shadow: hasShadow, canHide: canHide, hidesOnDeactivate: hidesOnDeactivate)
        isProjectionFullscreen = true
        Self.updatePresentationOptions()
        styleMask = .borderless; titleVisibility = .hidden; titlebarAppearsTransparent = true
        isMovable = false; isMovableByWindowBackground = false; hasShadow = false
        canHide = false; hidesOnDeactivate = false
        level = Self.workspaceTools.contains(self) ? Self.workspaceToolLevel : .normal
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(display.frame, display: false, animate: false)
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
