final class BorderWheelDocument: NSView { override var isFlipped: Bool { true } }
final class BorderWheelScrollView: NSScrollView {
    var receivedWheels = 0
    override func scrollWheel(with event: NSEvent) {
        receivedWheels += 1
        super.scrollWheel(with: event)
    }
}
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
// A border owns native input before selection or the empty-area reorder monitor.
let heightInput = TimelineTrackHeightResizeView(frame: host.bounds)
heightInput.configure(project: row.project, song: UUID(), tracks: [newTrack], offsets: [0], heights: [64],
                      laneCounts: [1], scales: [1], baseHeight: 64, top: 20,
                      verticalOffset: 0, excludedX: 290...310, blocked: false)
host.addSubview(heightInput)
var heightPreviews: [Double] = [], heightCommits = 0, heightCancels = 0
heightInput.change = { _, scale, ended in if ended { heightCommits += 1 } else { heightPreviews.append(scale) } }
heightInput.cancelled = { heightCancels += 1 }
func heightPointer(_ type: NSEvent.EventType, _ x: CGFloat = 100, _ y: CGFloat = 82) -> NSEvent {
    defer { timestamp += 1 }
    return NSEvent.mouseEvent(with: type, location: heightInput.convert(CGPoint(x: x, y: y), to: nil),
        modifierFlags: [], timestamp: timestamp, windowNumber: window.windowNumber, context: nil,
        eventNumber: 1, clickCount: 1, pressure: 1)!
}
precondition(heightInput.hitTest(host.convert(heightInput.convert(CGPoint(x: 100, y: 50), to: nil), from: nil)) == nil, "row interiors retain their control targets")
let edgePress = heightPointer(.leftMouseDown)
precondition(TimelineTrackHeightResizeView.handlesPointer(edgePress), "only an actual native border hit has height priority")
let selectionsBefore = newSelections
router.handle(edgePress)
precondition(router.pinnedTracks.isEmpty, "border presses must not arm row reordering")
let cursorBeforeHeightDrag = NSCursor.current
heightInput.mouseDown(with: edgePress)
precondition(NSCursor.current === NSCursor.resizeUpDown)
precondition(window.firstResponder === heightInput && window.firstResponder is TimelineGridKeyboardTarget, "height edits retain grid keyboard shortcuts")
for y in stride(from: CGFloat(84), through: 112, by: 2) { heightInput.mouseDragged(with: heightPointer(.leftMouseDragged, 100, y)) }
precondition(heightCommits == 0 && heightPreviews.count > 1, "live resizing remains a local preview")
heightInput.mouseUp(with: heightPointer(.leftMouseUp, 100, 112))
RunLoop.main.run(until: Date().addingTimeInterval(0.02))
precondition(heightCommits == 1 && newSelections == selectionsBefore && TrackReorderState.shared.starts == 0)
precondition(NSCursor.current === cursorBeforeHeightDrag, "release balances the native resize cursor")
precondition(!TimelineTrackHeightResizeView.cancelActiveDrag(in: window), "released borders leave Escape available to transport")
heightInput.mouseDown(with: edgePress)
heightInput.mouseDragged(with: heightPointer(.leftMouseDragged, 100, 95))
precondition(TimelineTrackHeightResizeView.cancelActiveDrag(in: window))
heightInput.mouseUp(with: heightPointer(.leftMouseUp, 100, 95))
precondition(heightCommits == 1 && heightCancels == 1, "Escape cancels preview without a project commit")
precondition(NSCursor.current === cursorBeforeHeightDrag, "Escape releases the resize cursor")
heightInput.mouseDown(with: edgePress)
NativeTimelineInputGate.shared.setBlocked(true, for: window)
precondition(heightCancels == 2 && !TimelineTrackHeightResizeView.cancelActiveDrag(in: window))
NativeTimelineInputGate.shared.setBlocked(false, for: window)
heightInput.mouseDown(with: edgePress)
heightInput.removeFromSuperview()
precondition(heightCancels == 3 && !TimelineTrackHeightResizeView.cancelActiveDrag(in: window), "detach releases cursor and gesture")
// Upper and lower handles share bounds, including rows with overlapping lanes.
host.addSubview(heightInput)
let topPress = heightPointer(.leftMouseDown, 100, 21)
heightInput.mouseDown(with: topPress)
heightInput.mouseDragged(with: heightPointer(.leftMouseDragged, 100, 10))
precondition(heightPreviews.last == 75.0 / 64, "pulling the upper edge up expands its own row")
heightInput.mouseDragged(with: heightPointer(.leftMouseDragged, 100, -1000))
precondition(heightPreviews.last == 240.0 / 64)
heightInput.mouseDragged(with: heightPointer(.leftMouseDragged, 100, 1000))
precondition(heightPreviews.last == 24.0 / 64)
heightInput.mouseUp(with: heightPointer(.leftMouseUp, 100, 1000))
precondition(heightCommits == 2 && NSCursor.current === cursorBeforeHeightDrag)
heightInput.configure(project: row.project, song: UUID(), tracks: [newTrack], offsets: [0], heights: [89.6],
                      laneCounts: [2], scales: [1], baseHeight: 64, top: 20,
                      verticalOffset: 0, excludedX: 290...310, blocked: false)
heightInput.mouseDown(with: heightPointer(.leftMouseDown, 100, 108))
heightInput.mouseDragged(with: heightPointer(.leftMouseDragged, 100, 150))
precondition(abs(heightPreviews.last! - 66 / (64 * 0.7)) < 1e-12, "row travel is divided among its existing lanes")
heightInput.mouseDragged(with: heightPointer(.leftMouseDragged, 100, 1000))
precondition(abs(heightPreviews.last! - 168 / (64 * 0.7)) < 1e-12)
heightInput.mouseDragged(with: heightPointer(.leftMouseDragged, 100, -1000))
precondition(abs(heightPreviews.last! - 26 / (64 * 0.7)) < 1e-12)
precondition(TimelineTrackHeightResizeView.cancelActiveDrag(in: window) && heightCommits == 2)
precondition(NSCursor.current === cursorBeforeHeightDrag)
precondition(!TimelineTrackHeightResizeView.handlesPointer(heightPointer(.leftMouseDown, 300, 108)), "the mixer divider retains width resizing")
heightInput.removeFromSuperview()
print("TRACK_BORDER_BOTH_EDGES_SINGLE_OVERLAPPING_LANE_LIMITS_AND_CURSOR_CLEANUP_OK")
print("TRACK_BORDER_PRIORITY_LOCAL_PREVIEW_SINGLE_COMMIT_ESCAPE_GATE_DETACH_OK")
window.close()
print("TRACK_ROW_RECYCLING_CAPTURED_SELECTION_MENU_GESTURE_PINNING_REC_EXCLUSION_AND_TITLE_RESET_OK")

// The resize surface is a sibling above the vertical scroll view, matching the
// production viewport overlay. AppKit must hit the scroll hierarchy for wheels
// even at the exact points where a mouse press starts a row-height gesture.
let wheelWindow = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: 320, height: 120),
                           styleMask: [.titled], backing: .buffered, defer: false)
wheelWindow.isReleasedWhenClosed = false
let wheelRoot = BorderWheelDocument(frame: CGRect(x: 0, y: 0, width: 320, height: 120))
wheelWindow.contentView = wheelRoot
let underlyingScroll = BorderWheelScrollView(frame: wheelRoot.bounds)
underlyingScroll.documentView = BorderWheelDocument(frame: CGRect(x: 0, y: 0, width: 320, height: 1000))
underlyingScroll.hasVerticalScroller = true
wheelRoot.addSubview(underlyingScroll)
let flippedRow = TrackRightClickView(frame: wheelRoot.bounds)
let flippedTrack = UUID()
flippedRow.track = flippedTrack; flippedRow.project = UUID()
var flippedSelections = 0
flippedRow.select = { flippedSelections += 1 }
wheelRoot.addSubview(flippedRow)
let border = TimelineTrackHeightResizeView(frame: wheelRoot.bounds)
border.configure(project: UUID(), song: UUID(), tracks: [UUID(), UUID()], offsets: [0, 64], heights: [64, 64],
                 laneCounts: [1, 1], scales: [1, 1], baseHeight: 64, top: 20,
                 verticalOffset: 0, excludedX: 290...310, blocked: false)
var borderPreviewCount = 0, borderCancelCount = 0
border.change = { _, _, ended in if !ended { borderPreviewCount += 1 } }
border.cancelled = { borderCancelCount += 1 }
wheelRoot.addSubview(border)
wheelRoot.layoutSubtreeIfNeeded()
wheelWindow.orderFront(nil)
for y: CGFloat in [21, 82, 85] {
    let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                     wheel1: -3, wheel2: 0, wheel3: 0)!
    let event = NSEvent(cgEvent: cg)!
    let before = underlyingScroll.receivedWheels
    let offsetBefore = underlyingScroll.contentView.bounds.minY
    // Only dequeuing supplies NSApp.currentEvent; direct sendEvent does not.
    // AppKit strips the window association from a synthetic queued wheel, so
    // resolve the real native hit target at the fixture's known border point.
    NSApplication.shared.postEvent(event, atStart: true)
    let queued = NSApplication.shared.nextEvent(matching: .scrollWheel, until: Date(timeIntervalSinceNow: 0.05), inMode: .default, dequeue: true)!
    precondition(NSApplication.shared.currentEvent?.type == .scrollWheel)
    let point = border.convert(CGPoint(x: 100, y: y), to: wheelRoot.superview)
    guard let hit = wheelRoot.hitTest(point) else { preconditionFailure("border must have a native hit target") }
    var ancestor: NSView? = hit
    while ancestor != nil && ancestor !== underlyingScroll { ancestor = ancestor?.superview }
    precondition(ancestor === underlyingScroll,
                 "a wheel at a row border must hit the underlying scroll hierarchy, not the resize overlay")
    hit.scrollWheel(with: queued)
    precondition(underlyingScroll.receivedWheels == before + 1,
                 "native wheel dispatch must cross upper/lower row borders to the underlying scroll view")
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
    precondition(underlyingScroll.contentView.bounds.minY > offsetBefore,
                 "plain wheel over a row border must move the native vertical viewport")
    precondition(borderPreviewCount == 0, "a wheel cannot begin an individual height preview")
}
let borderDown = NSEvent.mouseEvent(with: .leftMouseDown,
    location: border.convert(CGPoint(x: 100, y: 82), to: nil), modifierFlags: [], timestamp: 20,
    windowNumber: wheelWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
let borderUp = NSEvent.mouseEvent(with: .leftMouseUp, location: borderDown.locationInWindow,
    modifierFlags: [], timestamp: 21, windowNumber: wheelWindow.windowNumber, context: nil,
    eventNumber: 2, clickCount: 1, pressure: 0)!
NSApplication.shared.postEvent(borderDown, atStart: true)
let queuedDown = NSApplication.shared.nextEvent(matching: .leftMouseDown, until: Date(timeIntervalSinceNow: 0.05), inMode: .default, dequeue: true)!
precondition(queuedDown.type == .leftMouseDown && NSApplication.shared.currentEvent?.type == .leftMouseDown)
let downPoint = wheelRoot.superview!.convert(borderDown.locationInWindow, from: nil)
let downTarget = wheelRoot.hitTest(downPoint)
precondition(downTarget === border, "a mouse press at the wheel-tested border still hits the resize overlay")
precondition(TimelineTrackHeightResizeView.handlesPointer(borderDown),
             "the router must recognize the actual border beneath a flipped content root")
let mirroredInteriorDown = NSEvent.mouseEvent(with: .leftMouseDown,
    location: border.convert(CGPoint(x: 100, y: 38), to: nil), modifierFlags: [], timestamp: 22,
    windowNumber: wheelWindow.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 1)!
precondition(!TimelineTrackHeightResizeView.handlesPointer(mirroredInteriorDown),
             "flipped-root conversion must not mistake a vertically mirrored row interior for a border")
router.handle(borderDown)
precondition(router.pinnedTracks.isEmpty, "a flipped-root border must not arm track selection or reordering")
downTarget?.mouseDown(with: borderDown)
precondition(borderPreviewCount == 1 && wheelWindow.firstResponder === border,
             "the same border retains native mouse-down routing for individual resizing")
NSApplication.shared.postEvent(borderUp, atStart: true)
let queuedUp = NSApplication.shared.nextEvent(matching: .leftMouseUp, until: Date(timeIntervalSinceNow: 0.05), inMode: .default, dequeue: true)!
precondition(queuedUp.type == .leftMouseUp)
downTarget?.mouseUp(with: borderUp)
router.handle(borderUp)
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
precondition(borderCancelCount == 1 && !TimelineTrackHeightResizeView.cancelActiveDrag(in: wheelWindow),
             "native mouse-up releases an unchanged resize gesture")
precondition(flippedSelections == 0 && TrackReorderState.shared.starts == 0,
             "border priority must preserve selection and prevent a competing track reorder")
router.handle(mirroredInteriorDown)
precondition(router.pinnedTracks == [flippedTrack], "ordinary row interiors still arm the matching row")
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
precondition(flippedSelections == 1, "flipped-root row interiors retain their ordinary selection action")
router.handle(borderUp)
wheelWindow.close()
print("TRACK_BORDER_NATIVE_WHEEL_PASSES_TO_SCROLL_VIEW_AND_CLICK_STILL_RESIZES_OK")
print("TRACK_BORDER_FLIPPED_ROOT_COORDINATES_PRESERVE_SELECTION_AND_REORDER_PRIORITY_OK")

}
