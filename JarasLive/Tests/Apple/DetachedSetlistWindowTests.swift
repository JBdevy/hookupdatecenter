import SwiftUI
import AppKit

// This fixture checks window lifecycle; scale geometry has its own integration suite.
@MainActor final class InterfaceScaling {
    static let shared = InterfaceScaling()
    var factor: CGFloat { 1 }
    func register(_ window: NSWindow) {}
}
extension View { func interfaceScaled() -> some View { self } }
// Window level coordination is covered separately; this fixture only owns the
// detached Setlist lifecycle and does not mount a main workspace window.
@MainActor enum ProjectionWindow {
    static func followWorkspaceWindow(_ window: NSWindow) {}
}


MainActor.assumeIsolated {
    _ = NSApplication.shared
    let owner = DetachedSetlistWindow()
    var docks = 0
    owner.open(onDock: { docks += 1 }) { Text("Setlist") }
    let first = owner.window!
    precondition(owner.isDetached && owner.isVisible)
    owner.open(onDock: { docks += 1 }) { Text("Setlist updated") }
    precondition(owner.window === first, "Repeated detach must reuse a single window")
    owner.setPartsVisible(true)
    precondition(first.minSize.width == 560 && first.contentView!.frame.width >= 600,
                 "Opening Parts must leave enough width for both columns")
    first.setContentSize(NSSize(width: 800, height: first.contentView!.frame.height))
    owner.setPartsVisible(true)
    precondition(first.contentView!.frame.width == 800, "Parts must not shrink a wider user window")
    owner.setPartsVisible(false)
    precondition(first.minSize.width == 224 && first.contentView!.frame.width == 800,
                 "Closing Parts must relax the minimum without shrinking the user's window")
    owner.hide()
    precondition(owner.isDetached && !owner.isVisible && owner.window === first)
    owner.open(onDock: { docks += 1 }) { Text("Setlist shown") }
    precondition(owner.window === first && owner.isVisible)
    precondition(!owner.windowShouldClose(first))
    precondition(owner.window == nil && !owner.isVisible && !owner.isDetached && docks == 1,
                 "User close must dispose the floating host and restore its saved dock once")
    owner.open(onDock: { docks += 1 }) { Text("Next project") }
    owner.close()
    precondition(owner.window == nil && !owner.isDetached && docks == 1,
                 "Project teardown must not dock an outgoing project's Setlist")
    UserDefaults.standard.removeObject(forKey: "NSWindow Frame CatLiveDetachedSetlistTest")
    print("DETACHED_SETLIST_SINGLE_WINDOW_HIDE_SHOW_CLOSE_AND_PROJECT_TEARDOWN_OK")
}
