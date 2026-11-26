#if os(macOS)
import AppKit
import CoreGraphics
import QuartzCore

/// A presentation fills its display independently from the workspace and
/// leaves the system menu bar and Dock under macOS control.
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
    private static let workspaceTools = NSHashTable<NSWindow>.weakObjects()
    private static let independentWindows = NSHashTable<NSWindow>.weakObjects()
    private static weak var workspaceWindow: NSWindow?
    private static var workspaceIsActive = false
    private static var workspaceIsMinimized = false
    private static var suspendedWindows: [NSWindow] = []
    private static var workspaceIsSuspended: Bool {
        workspaceWindow != nil && (!workspaceIsActive || workspaceIsMinimized)
    }
    private static let workspaceConfirmations = NSHashTable<NSWindow>.weakObjects()
    private static var activationObservers: [NSObjectProtocol] = []
    static let workspaceToolLevel = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
    private static let workspaceConfirmationLevel = NSWindow.Level(rawValue: workspaceToolLevel.rawValue + 1)

    func followApplicationWindowOrder() { Self.followWorkspaceWindow(self, independent: true) }
    static func bindWorkspace(_ window: NSWindow) {
        guard workspaceWindow !== window else { return }
        workspaceWindow = window
        workspaceIsActive = NSApp.isActive
        workspaceIsMinimized = window.isMiniaturized
        observeWorkspaceActivation()
    }

    static func followWorkspaceWindow(_ window: NSWindow, independent: Bool = false) {
        window.animationBehavior = .none
        window.parent?.removeChildWindow(window)
        window.hidesOnDeactivate = false
        if let panel = window as? NSPanel { panel.isFloatingPanel = false }
        workspaceTools.add(window)
        if independent { independentWindows.add(window) }
        window.level = workspaceToolLevel
        observeWorkspaceActivation()
    }
    static func presentWorkspaceConfirmation(_ window: NSWindow) {
        workspaceConfirmations.add(window)
        observeWorkspaceActivation()
        window.level = NSApp.isActive ? workspaceConfirmationLevel : .normal
        window.makeKeyAndOrderFront(nil)
    }
    static func dismissWorkspaceConfirmation(_ window: NSWindow) {
        workspaceConfirmations.remove(window)
        window.level = .normal
    }
    private static func observeWorkspaceActivation() {
        guard activationObservers.isEmpty else { return }
        activationObservers = [
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                Self.workspaceIsActive = true
                Self.setWorkspaceToolsActive(true)
                Self.syncWorkspaceWindows()
            },
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
                Self.workspaceIsActive = false
                Self.setWorkspaceToolsActive(false)
                Self.syncWorkspaceWindows()
            },
            NotificationCenter.default.addObserver(forName: NSWindow.didMiniaturizeNotification, object: nil, queue: .main) { notification in
                guard let window = notification.object as? NSWindow, window === Self.workspaceWindow else { return }
                Self.workspaceIsMinimized = true
                Self.syncWorkspaceWindows()
            },
            NotificationCenter.default.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: nil, queue: .main) { notification in
                guard let window = notification.object as? NSWindow, window === Self.workspaceWindow else { return }
                Self.workspaceIsMinimized = false
                Self.syncWorkspaceWindows()
            },
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { notification in
                guard let window = notification.object as? NSWindow else { return }
                if window === Self.workspaceWindow {
                    Self.workspaceWindow = nil
                    Self.suspendedWindows.removeAll()
                } else {
                    Self.suspendedWindows.removeAll { $0 === window }
                }
            }
        ]
    }

    private static func syncWorkspaceWindows() {
        guard let main = workspaceWindow else { return }
        if workspaceIsSuspended {
            let ordered = NSApp.orderedWindows
            let listed = Set(ordered.map(ObjectIdentifier.init))
            let windows = ordered + NSApp.windows.filter { !listed.contains(ObjectIdentifier($0)) }
            let tools = windows.filter { window in
                window !== main && window !== NSApp.modalWindow && window.isVisible && !window.isMiniaturized &&
                    window.parent == nil && window.sheetParent == nil && !independentWindows.contains(window) &&
                    (workspaceTools.contains(window) || window.styleMask.contains(.titled))
            }
            for window in tools {
                if !suspendedWindows.contains(where: { $0 === window }) { suspendedWindows.append(window) }
                window.orderOut(nil)
            }
        } else {
            let restoring = suspendedWindows
            suspendedWindows.removeAll()
            for window in restoring.reversed() where !window.isVisible && !window.isMiniaturized {
                if workspaceTools.contains(window) { window.level = workspaceToolLevel }
                window.orderFront(nil)
            }
        }
    }

    private static func setWorkspaceToolsActive(_ active: Bool) {
        // Leave existing sibling order intact. AppKit handles key-window
        // changes within the tool tier, so pointer events need no reordering.
        let level = active ? workspaceToolLevel : .normal
        for window in NSApp.orderedWindows.reversed() where workspaceTools.contains(window) && window.level != level {
            window.level = level
        }
        for window in workspaceConfirmations.allObjects {
            window.level = active ? workspaceConfirmationLevel : .normal
        }
    }
    static func presentWorkspaceWindow(_ window: NSWindow, activates: Bool = true) {
        if !workspaceTools.contains(window) { followWorkspaceWindow(window) }
        if workspaceIsSuspended && !independentWindows.contains(window) {
            if !suspendedWindows.contains(where: { $0 === window }) { suspendedWindows.insert(window, at: 0) }
            window.orderOut(nil)
            return
        }
        if window.level != workspaceToolLevel { window.level = workspaceToolLevel }
        if activates { window.makeKeyAndOrderFront(nil) }
        else { window.orderFront(nil) }
    }
    private var changingPresentation = false
    private func savePlacement() {
        guard !changingPresentation, !inLiveResize, let placementKey else { return }
        let defaults = UserDefaults.standard
        let placement = NSStringFromRect(saved?.frame ?? frame)
        if defaults.string(forKey: placementKey + ".frame") != placement {
            defaults.set(placement, forKey: placementKey + ".frame")
        }
        if defaults.bool(forKey: placementKey + ".fullscreen") != isProjectionFullscreen {
            defaults.set(isProjectionFullscreen, forKey: placementKey + ".fullscreen")
        }
        let display = NSStringFromRect(screen?.frame ?? frame)
        if defaults.string(forKey: placementKey + ".screen") != display {
            defaults.set(display, forKey: placementKey + ".screen")
        }
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
            toggleProjectionFullscreen(on: NSScreen.screens.first { $0.frame == savedScreen }, presenting: false)
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
    func toggleProjectionFullscreen(on target: NSScreen? = nil, presenting: Bool = true) {
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
            if presenting {
                contentView?.layoutSubtreeIfNeeded()
                if isVisible { contentView?.displayIfNeeded() }
            }
            NSAnimationContext.endGrouping()
            CATransaction.commit()
            changingPresentation = wasChanging
            savePlacement()
        }
        if let state = saved {
            saved = nil; isProjectionFullscreen = false
            styleMask = state.style; collectionBehavior = state.behavior; level = state.level
            titleVisibility = state.title; titlebarAppearsTransparent = state.transparentTitlebar
            isMovable = state.movable; isMovableByWindowBackground = state.movableByBackground
            hasShadow = state.shadow; canHide = state.canHide; hidesOnDeactivate = state.hidesOnDeactivate
            setFrame(state.frame, display: false, animate: false)
            if presenting { makeKeyAndOrderFront(nil) }
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
        level = Self.workspaceTools.contains(self) ? Self.workspaceToolLevel : .normal
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(display.frame, display: false, animate: false)
        if presenting { makeKeyAndOrderFront(nil) }
    }
    override func close() {
        savePlacement()
        changingPresentation = true
        // Reopening creates a fresh window from the saved placement. Avoid a
        // fullscreen-to-windowed relayout and a second key-window transition.
        isProjectionFullscreen = false
        saved = nil
        parent?.removeChildWindow(self)
        super.close()
    }
}
#endif
