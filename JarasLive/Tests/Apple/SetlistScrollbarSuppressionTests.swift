MainActor.assumeIsolated {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 240),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let root = NSView(frame: window.contentLayoutRect)
    window.contentView = root
    func makeScroll(_ x: CGFloat) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: x, y: 0, width: 300, height: 200))
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .legacy
        scroll.hasVerticalScroller = true
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 1800))
        root.addSubview(scroll)
        return scroll
    }
    let setlist = makeScroll(0), other = makeScroll(320)
    let probe = SetlistScrollbarSuppressionView(frame: NSRect(x: 0, y: 0, width: 300, height: 1800))
    setlist.documentView!.addSubview(probe)
    func settle() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        root.layoutSubtreeIfNeeded()
    }
    settle()
    precondition(!setlist.hasVerticalScroller && setlist.verticalScroller == nil)
    precondition(other.hasVerticalScroller, "Suppression must be scoped to its own list")
    precondition(probe.hitTest(.zero) == nil, "Background helper must not intercept the song list")
    // AppKit/SwiftUI may reenable and replace the native indicator without
    // relaying out this representable, especially with always-visible scrollers.
    for _ in 0..<3 {
        setlist.hasVerticalScroller = true
        setlist.verticalScroller = NSScroller()
        setlist.hasHorizontalScroller = true
        setlist.horizontalScroller = NSScroller()
        setlist.reflectScrolledClipView(setlist.contentView)
        settle()
        precondition(!setlist.hasVerticalScroller && !setlist.hasHorizontalScroller)
        precondition(setlist.verticalScroller == nil && setlist.horizontalScroller == nil)
        precondition(abs(setlist.contentView.frame.width - 300) < 0.1, "Hidden scrollers must not reserve a gutter")
    }
    setlist.contentView.scroll(to: NSPoint(x: 0, y: 500))
    setlist.reflectScrolledClipView(setlist.contentView)
    precondition(abs(setlist.contentView.bounds.origin.y - 500) < 0.1, "Native scrolling must continue working")
    probe.removeFromSuperview()
    other.documentView!.addSubview(probe)
    setlist.hasVerticalScroller = true
    other.hasVerticalScroller = true
    settle()
    precondition(setlist.hasVerticalScroller && !other.hasVerticalScroller, "Reparenting must release the old scroll view")
    probe.removeFromSuperview()
    other.hasVerticalScroller = true
    settle()
    precondition(other.hasVerticalScroller, "Removed helper retained an active observation")
    print("SETLIST_NATIVE_SCROLLBAR_RESTORATION_REPARENT_SCROLL_AND_GUTTER_OK")
}
