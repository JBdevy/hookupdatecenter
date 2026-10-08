import AppKit
import SwiftUI

private final class ChromeGeometryProbe: NSView { var name = "" }
private final class ChromeCloseHandler: NSObject {
    var calls = 0
    @objc func requestSaveBeforeClosing(_ sender: Any?) { calls += 1 }
}
private struct ChromeProbe: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> ChromeGeometryProbe {
        let view = ChromeGeometryProbe(); view.name = name; return view
    }
    func updateNSView(_ view: ChromeGeometryProbe, context: Context) {}
}
private struct ChromeFixture: View {
    var body: some View {
        VStack(spacing: 0) {
            Color.yellow.frame(height: 88).overlay(ChromeProbe(name: "transport"))
            GeometryReader { _ in Color.black }.overlay(ChromeProbe(name: "grid"))
            Color.gray.frame(height: 27).overlay(ChromeProbe(name: "footer"))
        }
        .overlay {
            GeometryReader { geometry in
                JarasTheme.titlebar.frame(height: geometry.safeAreaInsets.top)
                    .frame(maxHeight: .infinity, alignment: .top).ignoresSafeArea(edges: .top)
            }.allowsHitTesting(false)
        }
    }
}
private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
}
private func settle(_ window: NSWindow) {
    window.contentView?.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    window.contentView?.layoutSubtreeIfNeeded()
}
private func makeWindow(size: NSSize) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
    window.contentView = NSHostingView(rootView: ChromeFixture())
    window.setFrame(NSRect(origin: CGPoint(x: 70, y: 80), size: size), display: false)
    settle(window)
    return window
}
private func geometry(_ window: NSWindow) -> [NSRect] {
    let probes = descendants(ChromeGeometryProbe.self, in: window.contentView!).sorted { $0.name < $1.name }
    let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
    return probes.map { $0.convert($0.bounds, to: nil) } + buttons.map { $0.convert($0.bounds, to: nil) }
}

MainActor.assumeIsolated {
    precondition(ProjectTitlebarVersionView.text(for: "1.0.0") == "CatLive Version 1.00")
    precondition(ProjectTitlebarVersionView.text(for: "1.1.0") == "CatLive Version 1.01")
    precondition(ProjectTitlebarVersionView.text(for: "1.12.0") == "CatLive Version 1.12")
    precondition(ProjectTitlebarVersionView.text(for: "2.0.0") == "CatLive Version 2.00")
    _ = NSApplication.shared
    UserDefaults.standard.removeObject(forKey: "jaras.editorWindowFrame")
    for size in [NSSize(width: 1440, height: 791), NSSize(width: 600, height: 460), NSSize(width: 840, height: 540)] {
        let window = makeWindow(size: size)
        let frame = window.frame, positions = geometry(window), layout = window.contentLayoutRect
        let style = window.styleMask, title = window.titleVisibility, transparent = window.titlebarAppearsTransparent
        let behavior = window.collectionBehavior, movable = window.isMovable
        let close = window.standardWindowButton(.closeButton)!, closeHandler = ChromeCloseHandler()
        close.target = closeHandler; close.action = #selector(ChromeCloseHandler.requestSaveBeforeClosing(_:))
        ProjectWindowAnchor.configureChrome(of: window)
        settle(window)
        precondition(window.frame == frame && window.contentLayoutRect == layout, "chrome must preserve both outer frame and usable content")
        precondition(geometry(window) == positions, "transport, grid, footer and native titlebar controls must remain in place")
        precondition(window.styleMask == style.subtracting(.fullSizeContentView))
        precondition(window.titleVisibility == title && window.titlebarAppearsTransparent == transparent)
        precondition(window.collectionBehavior == behavior && window.isMovable == movable, "native window movement and fullscreen behavior remain available")
        precondition(window.backgroundColor == NSColor(JarasTheme.titlebar))
        precondition(window.standardWindowButton(.closeButton) === close, "changing chrome must not replace the guarded close button")
        precondition(close.target === closeHandler && close.action == #selector(ChromeCloseHandler.requestSaveBeforeClosing(_:)))
        close.performClick(nil)
        precondition(closeHandler.calls == 1, "the close button must still route through the save-confirmation handler")
        let resized = NSRect(origin: frame.origin, size: NSSize(width: size.width + 80, height: size.height + 40))
        window.setFrame(resized, display: false)
        ProjectWindowAnchor.configureChrome(of: window)
        precondition(window.frame == resized, "repeated configuration must preserve user resizing")
        window.close()
    }

    let documents = ProjectDocuments(), window = makeWindow(size: NSSize(width: 600, height: 460))
    let anchor = ProjectWindowAnchor(); anchor.documents = documents
    window.contentView!.addSubview(anchor)
    settle(window)
    precondition(window.frame.size == NSSize(width: 600, height: 460), "browser must not gain an extra titlebar height")
    documents.folderReview = true; anchor.update(); settle(window)
    precondition(window.frame.size == NSSize(width: 840, height: 540))
    anchor.editor = true; anchor.update(); settle(window)
    let available = window.screen?.visibleFrame.size ?? ProjectWindowAnchor.editorFrameSize
    precondition(window.frame.size == NSSize(width: min(1440, available.width), height: min(791, available.height)))
    anchor.editor = false; documents.folderReview = nil; anchor.update(); settle(window)
    precondition(window.frame.size == NSSize(width: 600, height: 460), "returning to the browser must restore its original outer size")
    let resized = NSRect(origin: window.frame.origin, size: NSSize(width: 720, height: 510))
    window.setFrame(resized, display: false); anchor.update(); settle(window)
    precondition(window.frame == resized, "ordinary view updates must not reset a resized window")
    let replacement = makeWindow(size: NSSize(width: 700, height: 500))
    anchor.removeFromSuperview(); replacement.contentView!.addSubview(anchor); settle(replacement)
    precondition(!replacement.styleMask.contains(.fullSizeContentView) && replacement.frame.size == NSSize(width: 600, height: 460))
    replacement.close(); window.close()
    let editorWindow = makeWindow(size: NSSize(width: 600, height: 460))
    let editorAnchor = ProjectWindowAnchor(); editorAnchor.editor = true
    editorWindow.contentView!.addSubview(editorAnchor); editorAnchor.update(); settle(editorWindow)
    let screen = NSScreen.screens.last!.visibleFrame
    // The flexible fixture host has no MainView minimum-width constraint.
    // Use a legal editor width directly rather than its transient minSize.
    let rememberedSize = NSSize(width: min(ProjectWindowAnchor.editorFrameSize.width, screen.width), height: min(700, screen.height))
    let rememberedOrigin = NSPoint(x: screen.minX + min(15, screen.width - rememberedSize.width),
                                    y: screen.minY + min(20, screen.height - rememberedSize.height))
    let remembered = NSRect(origin: rememberedOrigin, size: rememberedSize)
    editorWindow.setFrame(remembered, display: false); settle(editorWindow)
    editorWindow.close()
    let reopened = makeWindow(size: NSSize(width: 600, height: 460))
    let reopenedAnchor = ProjectWindowAnchor(); reopenedAnchor.editor = true
    reopened.contentView!.addSubview(reopenedAnchor); reopenedAnchor.update(); settle(reopened)
    precondition(reopened.frame == remembered, "reopening restores the editor size and position on its previous screen")
    reopened.close()
    UserDefaults.standard.removeObject(forKey: "jaras.editorWindowFrame")
    print("EDITOR_WINDOW_SCREEN_POSITION_AND_SIZE_RESTORED_OK")
    print("PROJECT_WINDOW_CHROME_CONTENT_TRAFFIC_LIGHTS_BROWSER_AND_REATTACH_OK")
}
