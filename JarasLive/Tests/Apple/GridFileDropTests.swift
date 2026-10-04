import AppKit
import SwiftUI

// The standalone grid test does not load the application's FX editor module.
private struct TestOpenFXKey: EnvironmentKey { static let defaultValue: (UUID?, String) -> Void = { _, _ in } }
private struct TestOpenClipFXChainKey: EnvironmentKey { static let defaultValue: (UUID) -> Void = { _ in } }
private struct TestEditTextItemKey: EnvironmentKey { static let defaultValue: (UUID) -> Void = { _ in } }
private struct TestGridInteractionBlockedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var openFX: (UUID?, String) -> Void { get { self[TestOpenFXKey.self] } set { self[TestOpenFXKey.self] = newValue } }
    var openClipFXChain: (UUID) -> Void { get { self[TestOpenClipFXChainKey.self] } set { self[TestOpenClipFXChainKey.self] = newValue } }
    var editTextItem: (UUID) -> Void { get { self[TestEditTextItemKey.self] } set { self[TestEditTextItemKey.self] = newValue } }
    var gridInteractionBlocked: Bool { get { self[TestGridInteractionBlockedKey.self] } set { self[TestGridInteractionBlockedKey.self] = newValue } }
}

final class TestDragInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingLocation = NSPoint.zero
    var draggedImageLocation = NSPoint.zero
    var draggedImage: NSImage? { nil }
    let draggingPasteboard: NSPasteboard
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(pasteboard: NSPasteboard) { draggingPasteboard = pasteboard; super.init() }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
final class DropDocument: NSView { override var isFlipped: Bool { true } }
let application = NSApplication.shared
let window = NSWindow(contentRect: NSRect(x: 90, y: 90, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
let scroll = GridNativeScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
let document = DropDocument(frame: NSRect(x: 0, y: 0, width: 3000, height: 1800))
window.contentView = scroll; scroll.documentView = document
scroll.contentView.scroll(to: NSPoint(x: 230, y: 100)); scroll.reflectScrolledClipView(scroll.contentView)
var previews: [CGPoint?] = []
var drops: [([URL], CGPoint)] = []
var previewSources: [[URL]] = []
scroll.fileDropPreview = { urls, point in previewSources.append(urls); previews.append(point) }
scroll.fileDrop = { urls, point in drops.append((urls, point)); return true }

let pasteboard = NSPasteboard.withUniqueName()
defer { pasteboard.releaseGlobally(); window.close() }
let urls = [URL(fileURLWithPath: "/tmp/jaras-not-copied-one.wav"), URL(fileURLWithPath: "/tmp/jaras-not-copied-two.wav")]
precondition(pasteboard.writeObjects(urls as [NSURL]))
let drag = TestDragInfo(pasteboard: pasteboard)
drag.draggingDestinationWindow = window
func point(_ x: CGFloat, _ y: CGFloat) { drag.draggingLocation = document.convert(NSPoint(x: x, y: y), to: nil) }
func expectClear(_ action: () -> Void) {
    point(320, 240)
    precondition(scroll.draggingEntered(drag) == .copy)
    let count = previews.count
    action()
    precondition(previewSources.last?.isEmpty == true, "ending a drag clears preview metadata")
    precondition(previews.count == count + 1 && previews.last! == nil, "every drag conclusion clears the insertion preview")
}
point(320, 240)
precondition(scroll.draggingEntered(drag) == .copy)
precondition(previews == [CGPoint(x: 320, y: 240)], "preview uses document coordinates, including the live scroll offset")
precondition(previewSources.last == urls, "drag preview receives source URLs before importing")
precondition(drops.isEmpty, "preview does not import or copy files")
precondition(scroll.draggingUpdated(drag) == .copy && previews.count == 1, "stationary drag updates do not redraw")
var modifiers: NSEvent.ModifierFlags = []
scroll.fileDropModifierFlags = { modifiers }
modifiers = .shift
precondition(scroll.draggingUpdated(drag) == .copy && previews.count == 2 && previews.last! == CGPoint(x: 320, y: 240), "stationary Shift press reruns free-placement preview snapping")
precondition(scroll.draggingUpdated(drag) == .copy && previews.count == 2, "identical point and Shift state do not redraw")
modifiers = []
precondition(scroll.draggingUpdated(drag) == .copy && previews.count == 3 && previews.last! == CGPoint(x: 320, y: 240), "stationary Shift release restores magnetic snapping before the drop")
point(610, 360)
precondition(scroll.draggingUpdated(drag) == .copy && previews.last! == CGPoint(x: 610, y: 360))
expectClear { scroll.draggingExited(drag) }
expectClear { scroll.draggingEnded(drag) }
expectClear { scroll.concludeDragOperation(drag) }
expectClear { precondition(scroll.performDragOperation(drag)) }
precondition(drops.count == 1 && drops[0].0 == urls && drops[0].1 == CGPoint(x: 320, y: 240), "the eventual import receives the same exact insertion coordinates")
let clearedCount = previews.count
scroll.draggingExited(nil); scroll.concludeDragOperation(nil)
precondition(previews.count == clearedCount, "duplicate clear events do not redraw")
scroll.fileDrop = { _, _ in false }
expectClear { precondition(!scroll.performDragOperation(drag)) }
drag.draggingSourceOperationMask = .move
precondition(scroll.draggingEntered(drag).isEmpty && !scroll.performDragOperation(drag), "copy-disallowed sources neither preview nor import")
drag.draggingSourceOperationMask = .copy
scroll.fileDrop = nil
precondition(scroll.draggingEntered(drag).isEmpty, "a grid without an importer does not advertise a drop")
scroll.fileDrop = { _, _ in preconditionFailure("non-file pasteboards must not import") }
pasteboard.clearContents(); pasteboard.setString("not a file URL", forType: .string)
precondition(scroll.draggingEntered(drag).isEmpty && !scroll.performDragOperation(drag), "internal/text drags never become external file previews")
precondition(previews.last! == nil)

// The real timeline places the horizontal grid inside an outer vertical scroll.
// File-drop coordinates must retain both live origins, without waiting for SwiftUI.
let outer = GridNativeScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
let column = DropDocument(frame: NSRect(x: 0, y: 0, width: 700, height: 1800))
let inner = GridNativeScrollView(frame: NSRect(x: 142, y: 0, width: 558, height: 1800))
let timeline = DropDocument(frame: NSRect(x: 0, y: 0, width: 3000, height: 1800))
window.contentView = outer; outer.documentView = column; column.addSubview(inner); inner.documentView = timeline
outer.contentView.scroll(to: NSPoint(x: 0, y: 410)); outer.reflectScrolledClipView(outer.contentView)
inner.contentView.scroll(to: NSPoint(x: 650, y: 0)); inner.reflectScrolledClipView(inner.contentView)
pasteboard.clearContents(); precondition(pasteboard.writeObjects(urls as [NSURL]))
var nestedPreview: CGPoint?
var nestedDrop: CGPoint?
inner.fileDropPreview = { _, point in nestedPreview = point }
inner.fileDrop = { _, position in nestedDrop = position; return true }
let timelinePosition = CGPoint(x: 875, y: 620)
drag.draggingLocation = timeline.convert(timelinePosition, to: nil)
precondition(inner.draggingEntered(drag) == .copy && nestedPreview == timelinePosition, "nested preview retains both live scroll origins")
precondition(inner.performDragOperation(drag) && nestedDrop == timelinePosition && nestedPreview == nil, "nested final drop matches the preview, including the destination track's y coordinate")
print("GRID_EXTERNAL_FILE_DROP_PREVIEW_COORDINATES_AND_LIFECYCLE_OK")
