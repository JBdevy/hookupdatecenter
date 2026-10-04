import AppKit
import SwiftUI

// INSERT_PLAYLIST_CLICK_VIEW

struct PlaylistWheelFixture: View {
    let selected: () -> Void
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(0..<50) { index in
                    Text("Song \(index)").frame(maxWidth: .infinity).frame(height: 34)
                        .overlay(PlaylistSelectionClick(action: selected))
                }
            }
        }.frame(width: 260, height: 200)
    }
}
func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
}
final class PlaylistWheelEvent: NSEvent {
    var target: NSWindow!
    var point = NSPoint.zero
    override var window: NSWindow? { target }
    override var locationInWindow: NSPoint { point }
    override var scrollingDeltaY: CGFloat { -6 }
    override var hasPreciseScrollingDeltas: Bool { false }
    override var modifierFlags: NSEvent.ModifierFlags { [] }
}
final class PlaylistBackgroundDocument: NSView { override var isFlipped: Bool { true } }
@MainActor func runTest() {
    _ = NSApplication.shared
    var selections = 0
    let host = NSHostingView(rootView: PlaylistWheelFixture { selections += 1 })
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 200))
    window.contentView = root
    let background = NSScrollView(frame: root.bounds)
    background.documentView = PlaylistBackgroundDocument(frame: NSRect(x: 0, y: 0, width: 260, height: 2000))
    root.addSubview(background)
    let controller = SidebarScrollController()
    controller.attach(background)
    host.frame = root.bounds
    root.addSubview(host)
    window.orderFront(nil)
    defer { window.close() }
    for _ in 0..<3 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03)) }
    let row = descendants(PlaylistSelectionClickView.self, in: host).first!
    guard let scroll = row.enclosingScrollView else { fatalError("Row must resolve its SwiftUI list scroll view") }
    let physicalWheel = PlaylistWheelEvent()
    physicalWheel.target = window
    physicalWheel.point = row.convert(NSPoint(x: 80, y: 10), to: nil)
    precondition(!controller.handleWheel(physicalWheel), "Setlist underneath the playlist chooser must not consume its mouse wheel")
    precondition(controller.metrics.offset == 0, "The covered Setlist must stay still")
    let before = scroll.contentView.bounds.origin.y
    let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -6, wheel2: 0, wheel3: 0)!
    row.scrollWheel(with: NSEvent(cgEvent: cg)!)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
    precondition(scroll.contentView.bounds.origin.y > before, "Mouse wheel over a song must move the playlist chooser")
    precondition(selections == 0, "Scrolling must not select songs")
    let click = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    row.mouseDown(with: click)
    precondition(selections == 1, "Selection overlay still receives clicks")
    // Closing either creation/addition panel restores physical-wheel routing.
    host.removeFromSuperview()
    precondition(controller.handleWheel(physicalWheel), "Setlist wheel resumes after the chooser closes")
    precondition(controller.metrics.offset > 0)
    print("PLAYLIST_SONG_MOUSE_WHEEL_SCROLLS_WITHOUT_SELECTING_OK")
}
MainActor.assumeIsolated { runTest() }
