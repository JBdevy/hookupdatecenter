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
slider.editingChanged = { if !$0 { commits += 1 } }
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
slider.synchronizeModel(dragged)
slider.synchronizeModel(-10)
precondition(slider.doubleValue == -10, "new external volume must still be accepted")
slider.mouseDown(with: event(.leftMouseDown, 30, 2))
slider.mouseUp(with: event(.leftMouseUp, 30, 2))
precondition(delivered == 0 && slider.doubleValue == 0 && commits == 2, "double click resets without a mouse-up jump")
print("FADER_INTERACTION_OK")
