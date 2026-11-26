import AppKit
import SwiftUI

final class PartsTestDocument: NSView { override var isFlipped: Bool { true } }
@MainActor func verifyPartsScrollbar() {
_ = NSApplication.shared
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 240))
window.contentView = root
let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 290, height: 240))
let document = PartsTestDocument(frame: NSRect(x: 0, y: 0, width: 290, height: 1600))
scroll.documentView = document; root.addSubview(scroll)
let controller = SidebarScrollController(); controller.attach(scroll)
let bar = PartsScrollbarView(frame: NSRect(x: 290, y: 0, width: 10, height: 240))
root.addSubview(bar); bar.attach(controller)
precondition(controller.metrics.canScroll && bar.thumb.width == 4)
func event(_ type: NSEvent.EventType, y: CGFloat) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: bar.convert(NSPoint(x: 5, y: y), to: nil), modifierFlags: [],
        timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
}
bar.mouseDown(with: event(.leftMouseDown, y: bar.thumb.midY))
bar.mouseDragged(with: event(.leftMouseDragged, y: 240))
bar.mouseUp(with: event(.leftMouseUp, y: 240))
precondition(abs(controller.metrics.offset - controller.metrics.maximumOffset) < 0.001,
             "Thin thumb keeps its full hit area and reaches the final section")
bar.mouseDown(with: event(.leftMouseDown, y: 0)); bar.mouseUp(with: event(.leftMouseUp, y: 0))
precondition(controller.metrics.offset == 0, "Click above the thumb returns to the first section")
scroll.frame.size.height = 120; bar.frame.size.height = 120; controller.refresh()
controller.scroll(to: controller.metrics.maximumOffset)
precondition(abs(bar.thumb.maxY - 117) < 0.001, "Thumb follows the viewport after panel resize")
document.frame.size.height = 50; controller.refresh()
precondition(!controller.metrics.canScroll && bar.thumb.isEmpty && bar.hitTest(NSPoint(x: 295, y: 60)) == nil,
             "A short list leaves no inactive scrollbar over its buttons")
bar.attach(nil); controller.attach(nil)
print("PARTS_THIN_GREEN_SCROLLBAR_DRAG_CLICK_RESIZE_AND_SHORT_LIST_OK")

}
MainActor.assumeIsolated { verifyPartsScrollbar() }
