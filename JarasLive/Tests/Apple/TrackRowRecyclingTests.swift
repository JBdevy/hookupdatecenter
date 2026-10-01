MainActor.assumeIsolated {

_ = NSApplication.shared
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
window.contentView = host
let row = TrackRightClickView(frame: host.bounds)
let originalTrack = UUID(), newTrack = UUID(), originalProject = UUID()
row.track = originalTrack; row.project = originalProject
var originalSelections = 0, newSelections = 0
row.select = { originalSelections += 1 }
host.addSubview(row)
var timestamp = 1.0
func pointer(_ type: NSEvent.EventType, _ x: CGFloat = 100, _ y: CGFloat = 60) -> NSEvent {
    defer { timestamp += 1 }
    return NSEvent.mouseEvent(with: type, location: host.convert(CGPoint(x: x, y: y), to: nil), modifierFlags: [], timestamp: timestamp, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
}
let router = TrackSelectionRouter.shared
router.handle(pointer(.leftMouseDown))
precondition(router.pinnedTracks == [originalTrack], "the original row is pinned before SwiftUI buttons receive mouseDown")
row.track = newTrack; row.select = { newSelections += 1 }
RunLoop.main.run(until: Date().addingTimeInterval(0.02))
precondition(originalSelections == 1 && newSelections == 0, "deferred selection uses the click's captured action even if its native row has rebound")
router.handle(pointer(.leftMouseUp))
precondition(router.pinnedTracks.isEmpty, "release allows the row slot to be recycled again")
router.handle(pointer(.leftMouseDown))
row.project = UUID()
RunLoop.main.run(until: Date().addingTimeInterval(0.02))
precondition(newSelections == 0, "a queued row click cannot cross a project switch")
router.handle(pointer(.leftMouseUp))

for (index, control) in ["REC", "M", "S", "Fader", "Pan"].enumerated() {
    let excluded = TrackControlSelectionExclusionView(frame: CGRect(x: 30 + index * 45, y: 40, width: 40, height: 40))
    host.addSubview(excluded)
    precondition(excluded.hitTest(.zero) == nil, "Selection exclusion must not consume control gestures")
    router.handle(pointer(.leftMouseDown, CGFloat(50 + index * 45), 60))
    precondition(router.pinnedTracks == [newTrack], "Control presses retain their row identity")
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    precondition(newSelections == 0, "Operating \(control) must preserve the previous track selection")
    router.handle(pointer(.leftMouseUp))
    excluded.removeFromSuperview()
}
router.handle(pointer(.leftMouseDown, 10, 60))
RunLoop.main.run(until: Date().addingTimeInterval(0.02))
precondition(newSelections == 1, "Clicking the track body still selects it")
router.handle(pointer(.leftMouseUp))

var originalPatch = 0, replacementPatch = 0, originalFX = 0, replacementFX = 0
row.patch = { originalPatch += 1 }; row.fx = { originalFX += 1 }
let snapshot = row.makeMenu()
row.patch = { replacementPatch += 1 }; row.fx = { replacementFX += 1 }
snapshot.actions[0].invoke(); snapshot.actions[1].invoke()
precondition(originalPatch == 1 && originalFX == 1 && replacementPatch == 0 && replacementFX == 0, "a menu retains the handlers of the track that opened it")
router.withPinnedTrack(originalTrack) {
    precondition(router.pinnedTracks == [originalTrack], "context menu tracking pins its original row")
    router.withPinnedTrack(originalTrack) { precondition(router.pinnedTracks.contains(originalTrack)) }
    precondition(router.pinnedTracks.contains(originalTrack), "nested tracking cannot unpin its outer menu")
}
precondition(router.pinnedTracks.isEmpty)

let title = TrackDragTitleView(frame: CGRect(x: 0, y: 0, width: 200, height: 16))
let dragState = TrackReorderState()
title.track = originalTrack; title.state = dragState
host.addSubview(title)
title.mouseDown(with: pointer(.leftMouseDown, 10, 8))
title.track = newTrack
title.mouseDragged(with: pointer(.leftMouseDragged, 50, 8))
precondition(dragState.starts == 0, "a pending title press cannot start dragging a replacement track")
title.mouseUp(with: pointer(.leftMouseUp, 50, 8))
title.mouseDown(with: pointer(.leftMouseDown, 10, 8))
title.project = UUID()
title.mouseDragged(with: pointer(.leftMouseDragged, 50, 8))
precondition(dragState.starts == 0, "a pending title press cannot cross a project switch either")
window.close()
print("TRACK_ROW_RECYCLING_CAPTURED_SELECTION_MENU_GESTURE_PINNING_REC_EXCLUSION_AND_TITLE_RESET_OK")

}
