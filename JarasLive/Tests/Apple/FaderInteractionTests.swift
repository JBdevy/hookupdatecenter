import AppKit

let app = NSApplication.shared
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
private let slider = DirectVolumeSliderView(frame: NSRect(x: 0, y: 0, width: 200, height: 27))
slider.minValue = -60; slider.maxValue = 12
slider.synchronizeModel(0)
window.contentView!.addSubview(slider)
var delivered = -60.0
var commits = 0
slider.changed = { delivered = $0 }
slider.editingChanged = { editing, _ in if !editing { commits += 1 } }
func event(_ type: NSEvent.EventType, _ x: Double, _ clicks: Int = 1) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 13), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
}
slider.mouseDown(with: event(.leftMouseDown, 100))
precondition(abs(delivered + 24) < 1, "click jumps directly to position")
slider.mouseDragged(with: event(.leftMouseDragged, 150))
let dragged = delivered
slider.synchronizeModel(0)
precondition(slider.doubleValue == dragged, "redraw during drag must not overwrite pointer")
slider.mouseUp(with: event(.leftMouseUp, 150))
precondition(delivered == dragged && slider.doubleValue == dragged && commits == 1, "release preserves dragged volume")
slider.synchronizeModel(0)
precondition(slider.doubleValue == dragged, "stale committed value after release must not revert fader")
slider.synchronizeModel(dragged - 2)
precondition(slider.doubleValue == dragged, "an out-of-order intermediate preview cannot overwrite the released pointer before final model confirmation")
slider.synchronizeModel(dragged)
slider.synchronizeModel(-10)
precondition(slider.doubleValue == -10, "new external volume must still be accepted")
slider.mouseDown(with: event(.leftMouseDown, 30, 2))
slider.mouseUp(with: event(.leftMouseUp, 30, 2))
precondition(delivered == 0 && slider.doubleValue == 0 && commits == 2, "double click resets without a mouse-up jump")

// Virtualization can remove a dragged row while the mouse is still down.
// Retain the original callback and pointer value through a model/view update,
// then complete after layout, even if mouseUp is delivered late.
var originalPreviews: [Double] = []
var originalCompletions: [Double] = []
var replacementPreviews: [Double] = []
var replacementCompletions: [Double] = []
slider.changed = { originalPreviews.append($0) }
slider.editingChanged = { editing, value in if !editing { originalCompletions.append(value) } }
slider.mouseDown(with: event(.leftMouseDown, 90))
slider.changed = { replacementPreviews.append($0) }
slider.editingChanged = { editing, value in if !editing { replacementCompletions.append(value) } }
slider.mouseDragged(with: event(.leftMouseDragged, 145))
let detachedValue = slider.doubleValue
let previewCount = originalPreviews.count
slider.removeFromSuperview()
precondition(!slider.trackingPointer && originalCompletions.isEmpty, "detaching ends native tracking without publishing during layout")
slider.finishPointerEditing(deferred: true)
slider.mouseUp(with: event(.leftMouseUp, 145))
slider.synchronizeModel(-8)
RunLoop.main.run(until: Date().addingTimeInterval(0.02))
precondition(originalCompletions == [detachedValue], "detachment commits the exact captured pointer value once to its original target")
precondition(originalPreviews.count == previewCount && replacementPreviews.isEmpty && replacementCompletions.isEmpty, "completion must not replay preview callbacks or target a replacement control")

// A queued completion must survive the native view itself being released.
var releasedCompletions: [Double] = []
private weak var releasedSlider: DirectVolumeSliderView?
var releasedValue = 0.0
autoreleasepool {
    let temporary = DirectVolumeSliderView(frame: NSRect(x: 0, y: 0, width: 200, height: 27))
    temporary.mini = true; temporary.minValue = -1; temporary.maxValue = 1
    temporary.synchronizeModel(0)
    temporary.editingChanged = { editing, value in if !editing { releasedCompletions.append(value) } }
    window.contentView!.addSubview(temporary)
    temporary.mouseDown(with: event(.leftMouseDown, 160))
    releasedValue = temporary.doubleValue
    window.makeFirstResponder(window.contentView)
    temporary.removeFromSuperview()
    releasedSlider = temporary
}
precondition(releasedSlider == nil, "the pan view is released before its deferred completion")
RunLoop.main.run(until: Date().addingTimeInterval(0.02))
precondition(releasedCompletions == [releasedValue], "detached pan completion survives without retaining or dereferencing its view")
print("FADER_INTERACTION_OK")

// A retained row slot can switch tracks without dismantling its slider. The
// same numeric model value belongs to a new target and must replace old preview.
private let recycled = DirectVolumeSliderView(frame: NSRect(x: 0, y: 0, width: 200, height: 27))
let firstProject = UUID(), nextProject = UUID(), firstTrack = UUID(), nextTrack = UUID()
recycled.rebind(project: firstProject, track: firstTrack)
recycled.synchronizeModel(0)
window.contentView!.addSubview(recycled)
var recycledCommits: [(UUID, Double)] = []
recycled.editingChanged = { editing, value in if !editing { recycledCommits.append((firstTrack, value)) } }
recycled.mouseDown(with: event(.leftMouseDown, 140))
let firstTargetValue = recycled.doubleValue
precondition(window.firstResponder === recycled)
recycled.rebind(project: firstProject, track: firstTrack)
recycled.synchronizeModel(0)
precondition(recycled.trackingPointer && recycled.doubleValue == firstTargetValue, "same-target redraw retains the active pointer edit")
recycled.rebind(project: firstProject, track: nextTrack)
recycled.synchronizeModel(0)
precondition(!recycled.trackingPointer && recycled.doubleValue == 0, "a different track resets stale preview even when both committed values equal zero")
precondition(window.firstResponder !== recycled, "keyboard focus cannot silently follow a recycled slider to another track")
precondition(recycledCommits.isEmpty, "rebinding during layout defers the old target's completion")
recycled.editingChanged = { editing, value in if !editing { recycledCommits.append((nextTrack, value)) } }
recycled.mouseUp(with: event(.leftMouseUp, 140))
recycled.mouseDown(with: event(.leftMouseDown, 110))
let nextTargetValue = recycled.doubleValue
RunLoop.main.run(until: Date().addingTimeInterval(0.02))
precondition(recycledCommits.count == 1 && recycledCommits[0].0 == firstTrack && recycledCommits[0].1 == firstTargetValue, "the captured old target commits once after reuse")
precondition(recycled.trackingPointer && recycled.doubleValue == nextTargetValue, "deferred old completion cannot alter the next target's pointer edit")
recycled.mouseUp(with: event(.leftMouseUp, 110))
precondition(recycledCommits.count == 2 && recycledCommits[1].0 == nextTrack && recycledCommits[1].1 == nextTargetValue, "new target independently commits its own value")
recycled.rebind(project: nextProject, track: nextTrack)
recycled.synchronizeModel(0)
precondition(recycled.doubleValue == 0 && !recycled.trackingPointer, "a different project also resets the cached value even if track IDs and committed values match")
recycled.rebind(project: nextProject, track: nil)
recycled.synchronizeModel(-2)
precondition(recycled.doubleValue == -2, "Master's nil-track identity stays distinct from a track")
print("FADER_RECYCLING_TARGET_IDENTITY_DEFERRED_COMPLETION_FOCUS_AND_MODEL_RESET_OK")

private let linkedA = DirectVolumeSliderView(frame: NSRect(x: 0,y: 0,width: 200,height: 27))
private let linkedB = DirectVolumeSliderView(frame: NSRect(x: 0,y: 30,width: 200,height: 27))
let linkedProject = UUID(), leftID = UUID(), rightID = UUID()
linkedA.rebind(project: linkedProject,track: leftID); linkedB.rebind(project: linkedProject,track: rightID)
linkedA.linkedTrack = rightID; linkedB.linkedTrack = leftID
window.contentView!.addSubview(linkedA); window.contentView!.addSubview(linkedB)
linkedA.synchronizeModel(0); linkedB.synchronizeModel(0)
linkedA.mouseDown(with: event(.leftMouseDown, 80))
linkedA.mouseDragged(with: event(.leftMouseDragged, 160))
precondition(linkedA.trackingPointer && linkedB.doubleValue == linkedA.doubleValue, "linked fader moves before mouseUp without waiting for SwiftUI")
linkedB.synchronizeModel(-12)
precondition(linkedB.doubleValue == linkedA.doubleValue, "delayed model redraw cannot overwrite the live partner")
linkedA.mouseUp(with: event(.leftMouseUp, 160))
linkedA.mini = true; linkedB.mini = true
linkedA.minValue = -1; linkedA.maxValue = 1; linkedB.minValue = -1; linkedB.maxValue = 1
linkedA.mouseDown(with: event(.leftMouseDown, 40))
linkedA.mouseDragged(with: event(.leftMouseDragged, 170))
precondition(linkedA.trackingPointer && linkedB.doubleValue == -linkedA.doubleValue, "linked pan mirrors each drag event before release")
linkedA.mouseUp(with: event(.leftMouseUp, 170))
linkedB.resetToUnity()
precondition(linkedA.doubleValue == 0 && linkedB.doubleValue == 0, "reset from either linked side centers both")
linkedB.linkedTrack = nil
let unlinkedValue = linkedB.doubleValue
linkedA.mouseDown(with: event(.leftMouseDown, 40))
precondition(linkedB.doubleValue == unlinkedValue, "unlinked controls cannot receive stale mirroring")
linkedA.mouseUp(with: event(.leftMouseUp, 40))
print("LINKED_FADER_AND_PAN_IMMEDIATE_DRAG_MIRROR_BEFORE_RELEASE_OK")

private let vertical = DirectVolumeSliderView(frame: NSRect(x: 210, y: 0, width: 28, height: 80))
vertical.vertical = true; vertical.rebind(project: firstProject, track: firstTrack)
private let duplicate = DirectVolumeSliderView(frame: NSRect(x: 0, y: 40, width: 200, height: 27))
duplicate.rebind(project: firstProject, track: firstTrack)
window.contentView!.addSubview(vertical); window.contentView!.addSubview(duplicate)
func localEvent(_ view: NSView, _ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
}
vertical.mouseDown(with: localEvent(vertical, .leftMouseDown, NSPoint(x: 14, y: 8)))
precondition(vertical.doubleValue == 12 && duplicate.doubleValue == 12, "vertical top is +12 and existing mixer mirrors before release")
vertical.mouseDragged(with: localEvent(vertical, .leftMouseDragged, NSPoint(x: 14, y: 72)))
precondition(vertical.doubleValue == -60 && duplicate.doubleValue == -60, "vertical bottom is silence and both mixers follow")
vertical.mouseUp(with: localEvent(vertical, .leftMouseUp, NSPoint(x: 14, y: 72)))
vertical.resetToUnity(); precondition(duplicate.doubleValue == 0)
vertical.mini = true; vertical.rotary = true; vertical.vertical = false; vertical.minValue = -1; vertical.maxValue = 1
vertical.mouseDown(with: localEvent(vertical, .leftMouseDown, NSPoint(x: 14, y: 40)))
precondition(vertical.doubleValue == 0, "knob mouseDown must not jump")
vertical.mouseDragged(with: localEvent(vertical, .leftMouseDragged, NSPoint(x: 14, y: 0)))
precondition(vertical.doubleValue == 0.5, "dragging knob up pans right with stable relative movement")
vertical.mouseUp(with: localEvent(vertical, .leftMouseUp, NSPoint(x: 14, y: 0)))
print("FOOTER_MIXER_VERTICAL_FADER_ROTARY_PAN_AND_SHARED_TRACK_LIVE_SYNC_OK")

// Selected, unlinked tracks receive their own computed value on each native event.
linkedA.linkedTrack = nil; linkedB.linkedTrack = nil
linkedA.mini = false; linkedB.mini = false
linkedA.minValue = -60; linkedA.maxValue = 12; linkedB.minValue = -60; linkedB.maxValue = 12
var groupValues: [UUID:Double] = [:]
linkedA.groupValues = { groupValues }
linkedA.changed = { value in
    let gain = value <= -60 ? 0 : pow(10, value / 20)
    groupValues = [leftID: gain, rightID: gain * 0.5]
}
linkedA.mouseDown(with: event(.leftMouseDown, 100))
linkedA.mouseDragged(with: event(.leftMouseDragged, 150))
precondition(abs(linkedB.doubleValue - (linkedA.doubleValue + 20 * log10(0.5))) < 0.000001, "Selected unlinked faders preserve their dB difference before release")
linkedA.mouseUp(with: event(.leftMouseUp, 150))
linkedA.mini = true; linkedB.mini = true
linkedA.minValue = -1; linkedA.maxValue = 1; linkedB.minValue = -1; linkedB.maxValue = 1
linkedA.changed = { groupValues = [leftID: $0, rightID: min(1, $0 + 0.2)] }
linkedA.mouseDown(with: event(.leftMouseDown, 100))
linkedA.mouseDragged(with: event(.leftMouseDragged, 130))
precondition(abs(linkedB.doubleValue - (linkedA.doubleValue + 0.2)) < 0.000001, "Selected pan follows live without becoming the inverse unless linked")
linkedA.mouseUp(with: event(.leftMouseUp, 130))
print("SELECTED_TRACK_FADER_AND_PAN_LIVE_MIRROR_BEFORE_RELEASE_OK")
