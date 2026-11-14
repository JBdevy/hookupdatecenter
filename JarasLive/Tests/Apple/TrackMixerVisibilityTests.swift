import AppKit
import SwiftUI

private enum VisibilityJournal { static var windowTransitions = 0 }

// INSERT_NATIVE_TRACK_MIXER_VISIBILITY

private final class VisibilityDocument: NSView {
    override var isFlipped: Bool { true }
}
private final class FocusProbe: NSView {
    override var acceptsFirstResponder: Bool { true }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    let window = NSWindow(contentRect: CGRect(x: -5000, y: -5000, width: 320, height: 320),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 320, height: 320))
    let document = VisibilityDocument(frame: CGRect(x: 0, y: 0, width: 320, height: 4096))
    scroll.documentView = document
    window.contentView = scroll
    window.orderFront(nil)
    defer { window.orderOut(nil); window.close() }
    let first = TrackMixerNativeControlView(frame: CGRect(x: 0, y: 64, width: 248, height: 64))
    let distantAncestor = VisibilityDocument(frame: CGRect(x: 0, y: 1800, width: 248, height: 64))
    let distant = TrackMixerNativeControlView(frame: CGRect(x: 0, y: 0, width: 248, height: 64))
    first.track = UUID(); distant.track = UUID()
    distant.controls.update(TrackMixerNativeContent(controls: AnyView(Button("Warm control") {})), meterWidth: 52, enabled: true)
    document.addSubview(first); document.addSubview(distantAncestor); distantAncestor.addSubview(distant)
    document.layoutSubtreeIfNeeded()
    first.place(); distant.place()
    let hosts: [NSView] = [distant.meter, distant.activity, distant.controls]
    let identities = hosts.map(ObjectIdentifier.init)
    let accessibility = app.isFullKeyboardAccessEnabled || NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled
    precondition(!first.isHidden, "visible rows remain available")
    precondition(distant.isHidden != accessibility, "only an offscreen non-accessibility row is hidden")
    precondition(hosts.allSatisfy { accessibility ? $0.superview === distant : $0.superview == nil }, "offscreen rows detach hosts, while assistive traversal keeps them mounted")

    // Reordering/height changes can move only a SwiftUI ancestor, leaving the
    // native controls, viewport and complete document at exactly the same size.
    let documentSize = document.frame.size
    distantAncestor.setFrameOrigin(CGPoint(x: 0, y: 150))
    precondition(!distant.isHidden, "an ancestor-only move into the viewport reveals controls synchronously")
    distantAncestor.setFrameOrigin(CGPoint(x: 0, y: 1800))
    precondition(hosts.allSatisfy { accessibility ? $0.window === window : $0.window == nil }, "warm roots leave the window hierarchy when offscreen")
    precondition(distant.isHidden != accessibility && document.frame.size == documentSize,
                 "an ancestor-only move out refreshes visibility without document resizing")

    // Enter the 256-point reserve before any pixel of the row is revealed.
    scroll.contentView.scroll(to: CGPoint(x: 0, y: 1300))
    precondition(!distant.isHidden, "incoming rows are ready before reaching the viewport")
    scroll.contentView.scroll(to: CGPoint(x: 0, y: 1770))
    precondition(!distant.isHidden, "a distant scrollbar jump immediately reveals its existing controls")
    precondition(distant.subviews.map(ObjectIdentifier.init) == identities, "scrolling preserves controls and their state")

    TrackSelectionRouter.shared.pinnedTracks.insert(distant.track!)
    scroll.contentView.scroll(to: .zero)
    precondition(!distant.isHidden, "active pointer and menu tracks cannot be hidden")
    TrackSelectionRouter.shared.pinnedTracks.removeAll()
    let focus = FocusProbe(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
    distant.addSubview(focus)
    precondition(window.makeFirstResponder(focus))
    distant.refreshViewportVisibility()
    precondition(!distant.isHidden && window.firstResponder === focus, "offscreen keyboard focus is preserved")
    window.makeFirstResponder(nil)
    scroll.contentView.scroll(to: CGPoint(x: 0, y: 1))
    precondition(distant.isHidden != accessibility, "an inactive row returns to the offscreen reserve")

    // Viewport resize reveals a retained row without rebinding its content.
    scroll.setFrameSize(CGSize(width: 320, height: 1900))
    scroll.tile()
    precondition(!distant.isHidden, "viewport growth reveals existing row controls")
    precondition(distant.subviews.prefix(3).map(ObjectIdentifier.init) == identities)
    distant.removeFromSuperview()
    precondition(!distant.isHidden, "a detached control leaves no stale visibility state")
    distantAncestor.addSubview(distant)
    distant.place()
    precondition(!distant.isHidden, "reattachment resumes visible controls")
    // A rapid wheel reversal must not detach/reattach the same hosting roots.
    // It still hides their controls immediately, then removes offscreen roots
    // from the window once the gesture is idle.
    scroll.setFrameSize(CGSize(width: 320, height: 320)); scroll.tile()
    scroll.contentView.scroll(to: .zero)
    let transitions = VisibilityJournal.windowTransitions
    for _ in 0..<20 {
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 3000))
        precondition(first.isHidden != accessibility)
        scroll.contentView.scroll(to: .zero)
        precondition(!first.isHidden)
    }
    let wheelTransitions = VisibilityJournal.windowTransitions - transitions
    print("TRACK_MIXER_FAST_SCROLL_HOST_WINDOW_TRANSITIONS=\(wheelTransitions)")
    if !CommandLine.arguments.contains("--legacy") {
        precondition(wheelTransitions == 0, "rapid reversal must reuse mounted native roots without window/environment churn")
    }
    scroll.contentView.scroll(to: CGPoint(x: 0, y: 3000))
    RunLoop.main.run(until: Date().addingTimeInterval(0.22))
    precondition(accessibility || first.controls.superview == nil,
                 "after scrolling rests, offscreen hosts leave the native traversal")
    scroll.contentView.scroll(to: .zero)
    precondition(!first.isHidden && first.controls.window === window,
                 "an idle-detached row reattaches synchronously when scrolled into view")

    // Command-wheel also moves rows across the reserve without scrolling:
    // the document grows/shrinks while the clip remains at the same origin.
    RunLoop.main.run(until: Date().addingTimeInterval(0.22))
    distantAncestor.setFrameOrigin(CGPoint(x: 0, y: 150))
    let beforeHeight = VisibilityJournal.windowTransitions
    let clipOrigin = scroll.contentView.bounds.origin
    for _ in 0..<20 {
        document.setFrameSize(CGSize(width: 320, height: 8192))
        distantAncestor.setFrameOrigin(CGPoint(x: 0, y: 1800))
        precondition(distant.isHidden != accessibility, "resizing must still hide controls outside the warm viewport")
        document.setFrameSize(CGSize(width: 320, height: 4096))
        distantAncestor.setFrameOrigin(CGPoint(x: 0, y: 150))
        precondition(!distant.isHidden && distant.controls.window === window,
                     "height reversal must reveal the retained controls immediately")
    }
    let heightTransitions = VisibilityJournal.windowTransitions - beforeHeight
    print("TRACK_MIXER_FAST_HEIGHT_HOST_WINDOW_TRANSITIONS=\(heightTransitions)")
    precondition(scroll.contentView.bounds.origin == clipOrigin, "fixture must exercise resize without scrolling")
    if !CommandLine.arguments.contains("--legacy") {
        precondition(heightTransitions == 0, "height reversal must not rebuild the native window environment")
    }
    document.setFrameSize(CGSize(width: 320, height: 8192))
    distantAncestor.setFrameOrigin(CGPoint(x: 0, y: 1800))
    RunLoop.main.run(until: Date().addingTimeInterval(0.22))
    precondition(accessibility || hosts.allSatisfy { $0.superview == nil },
                 "after height changes rest, offscreen controls must detach normally")
    distantAncestor.setFrameOrigin(CGPoint(x: 0, y: 150))
    precondition(!distant.isHidden && hosts.map(ObjectIdentifier.init) == identities && hosts.allSatisfy { $0.window === window },
                 "revealing an idle-detached row must preserve every control and its identity")
    print("TRACK_MIXER_NATIVE_VISIBILITY_DETACH_WARM_SCROLL_IDENTITY_PINNED_FOCUS_RESIZE_AND_REATTACH_OK")
}
