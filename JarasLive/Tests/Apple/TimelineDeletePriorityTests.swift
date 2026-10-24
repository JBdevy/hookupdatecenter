import AppKit
import SwiftUI



final class DeleteTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}
final class ControlMappings {
    static let shared = ControlMappings()
    var editing: Int?
    func handleKey(_ event: NSEvent) -> Bool { false }
}
final class PlaylistSelectionNotice {
    static let shared = PlaylistSelectionNotice()
    func present(_ name: String, in window: NSWindow) {}
}
// The production event routers see an envelope editor in the main document
// window. Its actual point geometry is covered by AutomationLaneInputTests.
final class AutomationLaneView: NSView, TimelineGridKeyboardTarget {
    var received: [UInt16] = []
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { received.append(event.keyCode) }
}

// INSERT_NATIVE_DELETE_HANDLERS

MainActor.assumeIsolated {
let app = NSApplication.shared
let window = DeleteTestWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
window.contentView = host
let grid = RegionShortcutView(frame: host.bounds), setlist = SetlistKeyView(frame: NSRect(x:400,y:0,width:200,height:400))
host.addSubview(grid); host.addSubview(setlist)
var items = 0, tracks = 0, deletedItems = 0, deletedTracks = 0, deletedRegions = 0
let router = EditorSelectionRouter.shared
let gridArea = EditorSelectionAreaView(frame: NSRect(x:0,y:0,width:400,height:400)); gridArea.scope = .grid
let trackArea = EditorSelectionAreaView(frame: NSRect(x:0,y:0,width:150,height:400)); trackArea.scope = .tracks
let listArea = EditorSelectionAreaView(frame: NSRect(x:400,y:0,width:200,height:400)); listArea.scope = .setlist
for area in [gridArea,trackArea,listArea] { host.addSubview(area) }
grid.hasDeletionSelection = { router.activeScope(in: window) == .tracks ? tracks > 0 : router.activeScope(in: window) == .grid && items > 0 }
grid.delete = {
    if router.activeScope(in: window) == .tracks { deletedTracks += tracks; tracks = 0 }
    else if router.activeScope(in: window) == .grid { deletedItems += items; items = 0 }
}
setlist.delete = { deletedRegions += 1 }
@MainActor func click(_ x: CGFloat, notifySetlist: Bool = true) {
    let event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x:x,y:100), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    router.handlePointer(event)
    if notifySetlist { setlist.notePointerEvent(event) }
}
func deletion(_ code: UInt16 = 51, repeatKey: Bool = false, flags: NSEvent.ModifierFlags = [], window target: NSWindow = window) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: target.windowNumber, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: repeatKey, keyCode: code)!
}
items = 2; tracks = 1; click(500)
precondition(SetlistKeyView.handleDelete(deletion()))
precondition(deletedRegions == 1 && deletedItems == 0 && deletedTracks == 0)
// A pointer consumer can stop the other monitors; the logical scope still wins.
click(50, notifySetlist: false)
precondition(RegionShortcutView.handleSelectedObjectsDelete(deletion()))
precondition(deletedTracks == 1 && deletedItems == 0 && items == 2)
tracks = 1; click(250)
precondition(RegionShortcutView.handleSelectedObjectsDelete(deletion(117)))
precondition(deletedItems == 2 && tracks == 1)
items = 1; click(50)
precondition(RegionShortcutView.handleSelectedObjectsDelete(deletion()))
precondition(deletedTracks == 2 && items == 1)
items = 1; tracks = 1
precondition(RegionShortcutView.handleSelectedObjectsDelete(deletion(repeatKey: true)))
precondition(items == 1 && tracks == 1, "held Delete cannot cascade through selections")
precondition(!SetlistKeyView.handleDelete(deletion(flags: .command)))
let envelope = AutomationLaneView(frame: NSRect(x: 350, y: 40, width: 200, height: 100))
host.addSubview(envelope)
precondition(window.makeFirstResponder(envelope))
for code: UInt16 in [51, 117, 53] {
    let event = deletion(code)
    precondition(RegionShortcutView.envelopeOwnsEditingKey(event), "focused envelope owns point deletion and drag cancellation")
    precondition(!RegionShortcutView.handleSelectedObjectsDelete(event), "stale item or track selection cannot steal envelope editing")
    precondition(!SetlistKeyView.handleDelete(event), "stale setlist selection cannot steal envelope editing")
    window.sendEvent(event)
}
precondition(envelope.received == [51, 117, 53], "AppKit delivers the protected keys to the envelope responder")
precondition(items == 1 && tracks == 1 && deletedRegions == 1, "editing envelope points preserves items, tracks and regions")
precondition(!RegionShortcutView.envelopeOwnsEditingKey(deletion(flags: .command)), "modifier shortcuts retain their normal owner")
window.makeFirstResponder(nil)
print("TIMELINE_ENVELOPE_KEYS_PRESERVE_ITEM_TRACK_REGION_SELECTIONS_OK")
NativeTimelineInputGate.shared.setBlocked(true, for: window)
precondition(!RegionShortcutView.handleSelectedObjectsDelete(deletion()), "modals preserve all selected objects")
NativeTimelineInputGate.shared.setBlocked(false, for: window)
let editor = NSTextView(frame: .zero); host.addSubview(editor); window.makeFirstResponder(editor)
precondition(!SetlistKeyView.handleDelete(deletion()), "text editing does not delete project objects")
window.makeFirstResponder(nil)
ControlMappings.shared.editing = 1
precondition(!SetlistKeyView.handleDelete(deletion()), "mapping editor captures keys")
ControlMappings.shared.editing = nil
let other = DeleteTestWindow(contentRect: window.frame, styleMask: [.titled], backing: .buffered, defer: false)
other.isReleasedWhenClosed = false
precondition(!RegionShortcutView.handleSelectedObjectsDelete(deletion(window: other)), "another window cannot delete this document's selection")
grid.removeFromSuperview()
precondition(!RegionShortcutView.handleSelectedObjectsDelete(deletion()), "unmounted timelines release their owner")
print("TIMELINE_DELETE_ITEMS_TRACKS_REGIONS_PRIORITY_FOCUS_REPEAT_AND_WINDOWS_OK")

}
