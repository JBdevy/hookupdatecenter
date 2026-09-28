import AppKit

let app = NSApplication.shared
let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 400,height: 300),styleMask: [.titled],backing: .buffered,defer: false)
window.isReleasedWhenClosed = false
let scroll = GridNativeScrollView(frame: NSRect(x: 0,y: 0,width: 400,height: 300))
let document = NSView(frame: NSRect(x: 0,y: 0,width: 4000,height: 300))
let wheel = TimelineWheelView(frame: NSRect(x: 0,y: 0,width: 4000,height: 300))
window.contentView = scroll; scroll.documentView = document; document.addSubview(wheel)
let gate = NativeTimelineInputGate.shared
let previousZoom = UserDefaults.standard.object(forKey: "jaras.timelineZoom")
defer {
    if let previousZoom { UserDefaults.standard.set(previousZoom,forKey: "jaras.timelineZoom") }
    else { UserDefaults.standard.removeObject(forKey: "jaras.timelineZoom") }
}
final class WheelInputEvent: NSEvent {
    var target: NSWindow?
    var modifiers: NSEvent.ModifierFlags = []
    var delta: CGFloat = 3
    var horizontalDelta: CGFloat = 0
    var momentum: NSEvent.Phase = []
    var precise = true
    var gesturePhase: NSEvent.Phase = .began
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { target }
    override var modifierFlags: NSEvent.ModifierFlags { modifiers }
    override var locationInWindow: NSPoint { NSPoint(x: 100,y: 100) }
    override var scrollingDeltaY: CGFloat { delta }
    override var scrollingDeltaX: CGFloat { horizontalDelta }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var phase: NSEvent.Phase { gesturePhase }
    override var momentumPhase: NSEvent.Phase { momentum }
    override var timestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
}
let event = WheelInputEvent(); event.target = window
var heights: [Double] = [], zoomUpdates = 0, rowHeight = 98.0
var zoomValues: [Double] = [], zoomTimes: [Double] = []
wheel.changeTrackHeight = { heights.append($0); rowHeight = min(240,max(58,rowHeight * $0)) }
wheel.changeZoom = { next,_ in
    zoomUpdates += 1; zoomValues.append(next); zoomTimes.append(ProcessInfo.processInfo.systemUptime)
}
for modifier: NSEvent.ModifierFlags in [.command,.control] {
    event.modifiers = modifier
    precondition(wheel.handleWheelEvent(event))
}
precondition(heights.count == 2 && heights.allSatisfy { abs($0 - exp(3 * 0.004)) < 0.00001 })
precondition(zoomUpdates == 0, "Cmd/Ctrl wheel changes track height without starting horizontal grid zoom")
event.delta = -100
precondition(wheel.handleWheelEvent(event))
precondition(abs(heights.last! - exp(-0.08)) < 0.00001, "extreme wheel input remains bounded")
event.momentum = .changed
_ = wheel.handleWheelEvent(event)
precondition(heights.count == 3, "track height does not drift from trackpad momentum")
event.momentum = []
for _ in 0..<30 { _ = wheel.handleWheelEvent(event) }
precondition(rowHeight == 58, "repeated shrinking remains at the layout's fader-preserving minimum")
event.delta = 100
for _ in 0..<30 { _ = wheel.handleWheelEvent(event) }
precondition(rowHeight == 240, "repeated expansion remains at the maximum track height")
scroll.contentView.scroll(to: NSPoint(x: 200,y: 0))
event.modifiers = .shift; event.delta = -10
let heightAfterVerticalZoom = rowHeight, updatesBeforePan = zoomUpdates
precondition(wheel.handleWheelEvent(event) && scroll.contentView.bounds.minX == 210)
precondition(rowHeight == heightAfterVerticalZoom && zoomUpdates == updatesBeforePan, "Shift pans without changing either zoom")
event.modifiers = []; event.delta = 0; event.horizontalDelta = -8
precondition(wheel.handleWheelEvent(event) && scroll.contentView.bounds.minX == 218, "a horizontal trackpad gesture remains independent of track-height zoom")
event.horizontalDelta = 0

// AppKit lazily initializes run-loop sources and view layout. Finish that work
// before measuring a frame; the assertions below test input scheduling, not startup.
window.contentView?.layoutSubtreeIfNeeded()
let warmupTimer = Timer(timeInterval: 0.005,repeats: true) { _ in }
RunLoop.main.add(warmupTimer,forMode: .common)
RunLoop.main.run(until: Date().addingTimeInterval(0.050))
warmupTimer.invalidate()

func resetZoomInput(precise: Bool = true) {
    gate.setBlocked(true,for: window); gate.setBlocked(false,for: window)
    wheel.acceptRenderedZoom(1); scroll.zoomAnchor = nil
    wheel.position = 0.5
    event.modifiers = []; event.momentum = []; event.horizontalDelta = 0
    event.precise = precise; event.gesturePhase = precise ? .began : []
    zoomValues.removeAll(); zoomTimes.removeAll()
}
func requireZoomFrame(after inputTime: Double, callbackCount: Int) {
    // One display-frame is the intended cadence. A run-loop turn can deliver
    // several animation frames; measure the first new frame, not its last one.
    let deadline = inputTime + 0.050
    while zoomValues.count < callbackCount && ProcessInfo.processInfo.systemUptime < deadline {
        _ = RunLoop.main.run(mode: .default,before: Date(timeIntervalSinceNow: 0.002))
    }
    precondition(zoomValues.count >= callbackCount,"continuous zoom events reach the next display frame")
    let latency = zoomTimes[callbackCount - 1] - inputTime
    print("ZOOM_FRAME_LATENCY_MS=" + String(format: "%.2f",latency * 1_000))
    precondition(latency <= 0.050,"latest zoom input reaches layout at the display-frame cadence, within bounded native scheduler tolerance")
}

resetZoomInput()
event.delta = 10
let firstTrackpadInput = ProcessInfo.processInfo.systemUptime
precondition(wheel.handleWheelEvent(event))
precondition(zoomValues.count == 1,"the first trackpad zoom callback occurs before the event handler returns")
precondition(zoomValues[0] > 1 && zoomValues[0] < exp(10 * 0.008),"the short transition begins on the input event")
precondition(zoomTimes[0] >= firstTrackpadInput)
event.gesturePhase = .changed
let burstInput = ProcessInfo.processInfo.systemUptime
for delta: CGFloat in [3,4,5] { event.delta = delta; precondition(wheel.handleWheelEvent(event)) }
precondition(zoomValues.count == 1,"a burst of trackpad input coalesces instead of laying out on each event")
requireZoomFrame(after: burstInput,callbackCount: 2)
precondition(zoomValues.last! > zoomValues[0] && zoomValues.last! < exp(22 * 0.008),"display frames advance toward the latest accumulated target")
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
precondition(abs(zoomValues.last! - exp(22 * 0.008)) < 1e-10,"a short transition settles at the full gesture target")

resetZoomInput(precise: false)
event.delta = 2
precondition(wheel.handleWheelEvent(event))
precondition(zoomValues.count == 1 && zoomValues[0] > 1 && zoomValues[0] < exp(2 * 0.09),"a mouse wheel begins moving synchronously")

resetZoomInput()
event.delta = 8
precondition(wheel.handleWheelEvent(event))
event.gesturePhase = .changed
let reversalInput = ProcessInfo.processInfo.systemUptime
for delta: CGFloat in [12,-30] { event.delta = delta; precondition(wheel.handleWheelEvent(event)) }
precondition(zoomValues.count == 1)
requireZoomFrame(after: reversalInput,callbackCount: 2)
precondition(zoomValues.last! < zoomValues[0],"reversing the fingers changes direction in the next display frame")
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
precondition(zoomValues.last! < 1,"reversal discards the old pending direction")
let settledUpdates = zoomValues.count
RunLoop.main.run(until: Date().addingTimeInterval(0.035))
precondition(zoomValues.count == settledUpdates,"after settling, idle frames add no stale target callback")

resetZoomInput()
event.delta = 8
precondition(wheel.handleWheelEvent(event))
event.gesturePhase = []; event.momentum = .changed
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
let releasedScale = zoomValues.last!
let releasedUpdates = zoomValues.count
for delta: CGFloat in [4,2,1] {
    event.delta = delta
    precondition(wheel.handleWheelEvent(event))
    RunLoop.main.run(until: Date().addingTimeInterval(0.025))
    precondition(zoomValues.count == releasedUpdates && zoomValues.last! == releasedScale, "trackpad inertia must not change zoom after the fingers stop")
}
let nativeMomentumUpdates = zoomValues.count
RunLoop.main.run(until: Date().addingTimeInterval(0.035))
precondition(zoomValues.count == nativeMomentumUpdates,"native momentum does not create an additional synthetic animation")

resetZoomInput()
event.delta = 10
precondition(wheel.handleWheelEvent(event) && zoomValues.count == 1)
event.gesturePhase = .changed; event.delta = 20
precondition(wheel.handleWheelEvent(event) && zoomValues.count == 1,"second zoom input is pending until the next display frame")
gate.setBlocked(true,for: window)
let stoppedUpdates = zoomUpdates, stoppedHeights = heights.count
RunLoop.main.run(until: Date().addingTimeInterval(0.06))
precondition(zoomUpdates == stoppedUpdates, "opening a native modal stops pending zoom immediately")
precondition(!wheel.handleWheelEvent(event), "modal wheel events pass to the editor without reaching the timeline")
event.modifiers = .command
precondition(!wheel.handleWheelEvent(event) && heights.count == stoppedHeights)

let ruler = TimelineRulerView(frame: NSRect(x: 0,y: 0,width: 400,height: 24))
document.addSubview(ruler)
var seeks = 0
ruler.seek = { _,_ in seeks += 1 }
func pointer(_ type: NSEvent.EventType) -> NSEvent {
    NSEvent.mouseEvent(with: type,location: ruler.convert(NSPoint(x: 100,y: 12),to: nil),modifierFlags: [],timestamp: ProcessInfo.processInfo.systemUptime,windowNumber: window.windowNumber,context: nil,eventNumber: 1,clickCount: 1,pressure: 1)!
}
ruler.rightMouseDown(with: pointer(.rightMouseDown))
precondition(seeks == 0)
gate.setBlocked(false,for: window)
ruler.mouseDown(with: pointer(.leftMouseDown))
gate.setBlocked(true,for: window); gate.setBlocked(false,for: window)
ruler.mouseUp(with: pointer(.leftMouseUp))
precondition(seeks == 0, "native modal opening cancels a pending ruler press")
ruler.rightMouseDown(with: pointer(.rightMouseDown))
ruler.rightMouseUp(with: pointer(.rightMouseUp))
precondition(seeks == 1, "the ruler resumes immediately after closing the modal")
var intervals: [(Double, Double)] = []
ruler.selectTime = { intervals.append(($0, $1)) }
func selectionEvent(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: ruler.convert(NSPoint(x: x, y: 12), to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
}
for (start, end): (CGFloat, CGFloat) in [(100, 300), (300, 100)] {
    let before = seeks
    ruler.rightMouseDown(with: selectionEvent(.rightMouseDown, x: start))
    ruler.rightMouseDragged(with: selectionEvent(.rightMouseDragged, x: end))
    ruler.rightMouseUp(with: selectionEvent(.rightMouseUp, x: end))
    precondition(seeks == before, "right drag selects an interval without moving the Sub Play cursor")
    precondition(intervals.last!.0 == start / 400 && intervals.last!.1 == end / 400, "both ruler drag directions preserve their endpoints")
}
ruler.rightMouseDown(with: selectionEvent(.rightMouseDown, x: 100))
gate.setBlocked(true, for: window); gate.setBlocked(false, for: window)
let beforeCancelled = intervals.count
ruler.rightMouseDragged(with: selectionEvent(.rightMouseDragged, x: 300))
ruler.rightMouseUp(with: selectionEvent(.rightMouseUp, x: 300))
precondition(intervals.count == beforeCancelled, "opening a modal cancels the pending interval gesture")
if #available(macOS 14.0, *) {
    window.orderFront(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    event.modifiers = []; event.delta = 1; event.momentum = []; event.gesturePhase = .began
    let beforeDisplayZoom = zoomUpdates
    precondition(wheel.handleWheelEvent(event))
    event.gesturePhase = .changed
    precondition(wheel.handleWheelEvent(event))
    RunLoop.main.run(until: Date().addingTimeInterval(0.08))
    precondition(zoomUpdates >= beforeDisplayZoom + 2, "the visible window display link applies the pending zoom")
    gate.setBlocked(true, for: window)
    let pausedUpdates = zoomUpdates
    RunLoop.main.run(until: Date().addingTimeInterval(0.04))
    precondition(zoomUpdates == pausedUpdates, "blocking input invalidates the display link")
}
window.close()
print("NATIVE_MODAL_GATE_IMMEDIATE_ZOOM_FRAME_COALESCING_REVERSAL_NO_ZOOM_INERTIA_AND_CMD_CTRL_TRACK_HEIGHT_OK")
