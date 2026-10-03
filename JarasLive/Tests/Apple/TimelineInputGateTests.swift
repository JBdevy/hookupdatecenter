import AppKit

let app = NSApplication.shared
let window = NSWindow(contentRect: NSRect(x: -10000,y: -10000,width: 400,height: 300),styleMask: [.titled],backing: .buffered,defer: false)
window.isReleasedWhenClosed = false
let scroll = GridNativeScrollView(frame: NSRect(x: 0,y: 0,width: 400,height: 300))
let document = NSView(frame: NSRect(x: 0,y: 0,width: 4000,height: 300))
let wheel = TimelineWheelView(frame: NSRect(x: 0,y: 0,width: 4000,height: 300))
window.contentView = scroll; scroll.documentView = document; document.addSubview(wheel)
let gate = NativeTimelineInputGate.shared
let previousZoom = TimelineViewportPreferences.storage.object(forKey: "jaras.timelineZoom")
let legacyZoomBeforeTest = UserDefaults.standard.object(forKey: "jaras.timelineZoom") as? NSObject
defer {
    if let previousZoom { TimelineViewportPreferences.storage.set(previousZoom,forKey: "jaras.timelineZoom") }
    else { TimelineViewportPreferences.storage.removeObject(forKey: "jaras.timelineZoom") }
}
// Native cursor navigation changes the viewport during the input update; it
// does not depend on a delayed dispatch or a synchronous whole-window layout.
wheel.focus(request: UUID(), x: 2400)
precondition(scroll.contentView.bounds.minX > 2000, "cursor navigation reveals its destination immediately")
final class WheelInputEvent: NSEvent {
    var target: NSWindow?
    var modifiers: NSEvent.ModifierFlags = []
    var delta: CGFloat = 3
    var horizontalDelta: CGFloat = 0
    var momentum: NSEvent.Phase = []
    var precise = true
    var gesturePhase: NSEvent.Phase = .began
    var inputTime = ProcessInfo.processInfo.systemUptime
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { target }
    override var modifierFlags: NSEvent.ModifierFlags { modifiers }
    override var locationInWindow: NSPoint { NSPoint(x: 100,y: 100) }
    override var scrollingDeltaY: CGFloat { delta }
    override var scrollingDeltaX: CGFloat { horizontalDelta }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var phase: NSEvent.Phase { gesturePhase }
    override var momentumPhase: NSEvent.Phase { momentum }
    override var timestamp: TimeInterval { inputTime }
}
let event = WheelInputEvent(); event.target = window
var heights: [Double] = [], zoomUpdates = 0, rowHeight = 98.0
var zoomValues: [Double] = [], zoomTimes: [Double] = []
var heightSmoothing: [Bool] = []
wheel.changeTrackHeight = { factor, smoothWheel in
    heights.append(factor); heightSmoothing.append(smoothWheel)
    rowHeight = Double(TimelineTrackHeightInput.height(from: CGFloat(rowHeight), factor: factor))
}
wheel.changeZoom = { next,_ in
    zoomUpdates += 1; zoomValues.append(next); zoomTimes.append(ProcessInfo.processInfo.systemUptime)
    scroll.zoomAnchor = nil
}
for modifier: NSEvent.ModifierFlags in [.command,.control] {
    event.modifiers = modifier
    precondition(wheel.handleWheelEvent(event))
}
precondition(heights.count == 2 && heights.allSatisfy { abs($0 - exp(3 * TimelineTrackHeightLimits.preciseSensitivity)) < 0.00001 })
precondition(zoomUpdates == 0, "Cmd/Ctrl wheel changes track height without starting horizontal grid zoom")
event.delta = -100
precondition(wheel.handleWheelEvent(event))
precondition(abs(heights.last! - exp(-TimelineTrackHeightLimits.maximumWheelStep)) < 0.00001, "extreme wheel input remains bounded")
event.momentum = .changed
_ = wheel.handleWheelEvent(event)
precondition(heights.count == 3, "track height does not drift from trackpad momentum")
event.momentum = []
for _ in 0..<30 { _ = wheel.handleWheelEvent(event) }
precondition(rowHeight == Double(TimelineTrackHeightLimits.minimum), "repeated shrinking remains at the default track height")
event.delta = 100
for _ in 0..<30 { _ = wheel.handleWheelEvent(event) }
precondition(rowHeight == 240, "repeated expansion remains at the maximum track height")
scroll.contentView.scroll(to: NSPoint(x: 200,y: 0))
event.modifiers = .shift; event.delta = -10
let heightAfterVerticalZoom = rowHeight, updatesBeforePan = zoomUpdates
precondition(wheel.handleWheelEvent(event) && scroll.contentView.bounds.minX == 220)
precondition(rowHeight == heightAfterVerticalZoom && zoomUpdates == updatesBeforePan, "Shift pans without changing either zoom")
event.modifiers = []; event.delta = 0; event.horizontalDelta = -8
precondition(wheel.handleWheelEvent(event) && scroll.contentView.bounds.minX == 228, "a horizontal trackpad gesture remains independent of track-height zoom")
event.horizontalDelta = 0

// Both input surfaces must tag only discrete wheel events for the short height
// transition. Precise deltas retain their existing direct path and momentum
// never becomes a synthetic height animation.
precondition(heightSmoothing.allSatisfy { !$0 }, "precise height events bypass wheel smoothing")
let mixerHeightInput = TimelineMixerHeightWheelView(frame: wheel.frame)
var mixerHeightRouting: [(Double, Bool)] = []
mixerHeightInput.change = { mixerHeightRouting.append(($0, $1)) }
document.addSubview(mixerHeightInput)
for precise in [false, true] {
    event.precise = precise; event.gesturePhase = precise ? .began : []
    event.modifiers = .command; event.delta = 1; event.inputTime += 1
    let count = heights.count
    precondition(wheel.handleWheelEvent(event) && heights.count == count + 1)
    precondition(heightSmoothing.last == !precise, "grid distinguishes discrete wheel from precise trackpad")
    precondition(mixerHeightInput.handle(event) && mixerHeightRouting.last!.1 == !precise,
                 "mixer and grid use the same input-specific height animation policy")
    precondition(abs(mixerHeightRouting.last!.0 - heights.last!) < 1e-12,
                 "animation routing must not change the height sensitivity")
}
let beforeHeightMomentum = (heights.count, mixerHeightRouting.count)
event.momentum = .changed
_ = wheel.handleWheelEvent(event); _ = mixerHeightInput.handle(event)
precondition(heights.count == beforeHeightMomentum.0 && mixerHeightRouting.count == beforeHeightMomentum.1,
             "trackpad momentum never starts a height animation on either surface")
event.momentum = []; event.modifiers = []; event.delta = 0; event.gesturePhase = .began
mixerHeightInput.removeFromSuperview()
print("HEIGHT_SMOOTHING_ONLY_DISCRETE_WHEEL_GRID_AND_MIXER_OK")

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
    event.inputTime = max(event.inputTime, ProcessInfo.processInfo.systemUptime) + 1.0 / 60
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
func requireWheelZoomTarget(_ target: Double, after inputTime: Double) {
    // The 90 ms mouse transition retains room for the next native display tick.
    let deadline = inputTime + 0.125
    while (zoomValues.last.map { abs($0 - target) > 1e-12 } ?? true) && ProcessInfo.processInfo.systemUptime < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
    }
    precondition(zoomValues.last.map { abs($0 - target) < 1e-12 } == true,
                 "mouse zoom reaches its complete input target within 125 ms")
    precondition(zoomTimes.last! - inputTime <= 0.125,
                 "mouse animation finishes within its bounded display deadline")
}
func requireMonotonicZoom(_ values: [Double], increasing: Bool) {
    precondition(zip(values, values.dropFirst()).allSatisfy { increasing ? $0.1 >= $0.0 : $0.1 <= $0.0 },
                 "mouse zoom cannot overshoot or resume an old direction")
}

// Fractional trackpad input used to wait for 1.33 accumulated points before
// changing scale. Exercise the actual event handler, including a zero-delta
// gesture begin, so a synchronous large-input test cannot hide that delay.
for tinyDelta: CGFloat in [0.1, 0.2, -0.1, -0.2] {
    resetZoomInput()
    event.delta = 0
    precondition(wheel.handleWheelEvent(event) && zoomValues.isEmpty)
    event.gesturePhase = .changed; event.delta = tinyDelta
    event.inputTime += 1.0 / 120
    precondition(wheel.handleWheelEvent(event))
    let initialLog = Double(tinyDelta) * TimelineZoomLimits.preciseSensitivity
    precondition(zoomValues.count == 1 && abs(log(zoomValues[0]) - initialLog) < 1e-12,
                 "the first fractional trackpad movement changes zoom before its event returns")
    let smallBurstInput = ProcessInfo.processInfo.systemUptime
    for delta in [tinyDelta, tinyDelta, -tinyDelta] {
        event.delta = delta; event.inputTime += 1.0 / 120
        precondition(wheel.handleWheelEvent(event))
    }
    precondition(zoomValues.count == 1, "fractional input still coalesces at the frame cadence")
    requireZoomFrame(after: smallBurstInput, callbackCount: 2)
    precondition(abs(log(zoomValues.last!) - initialLog * 2) < 1e-12,
                 "small reversals preserve the exact signed travel without dead zones")
}
print("FRACTIONAL_ZOOM_FIRST_RESPONSE_AND_REVERSALS_OK")

// A phase-ended gesture need not have a momentum tail. A later zero-delta
// begin must not inherit its axis and swallow the next gesture's movement.
resetZoomInput()
scroll.contentView.scroll(to: NSPoint(x: 200, y: 0))
event.delta = 0; event.horizontalDelta = -2
precondition(wheel.handleWheelEvent(event) && zoomValues.isEmpty)
event.gesturePhase = .ended; event.horizontalDelta = 0
precondition(wheel.handleWheelEvent(event))
event.gesturePhase = .began; event.inputTime += 1.0 / 60
precondition(wheel.handleWheelEvent(event))
event.gesturePhase = .changed; event.delta = 0.1; event.inputTime += 1.0 / 60
precondition(wheel.handleWheelEvent(event) && zoomValues.count == 1,
             "vertical motion after a zero-delta begin cannot inherit the previous horizontal axis")
event.gesturePhase = .ended; event.delta = 0
precondition(wheel.handleWheelEvent(event))
event.gesturePhase = .began; event.inputTime += 1.0 / 60
precondition(wheel.handleWheelEvent(event))
event.gesturePhase = .changed; event.horizontalDelta = -2; event.inputTime += 1.0 / 60
let beforeHorizontalRestart = scroll.contentView.bounds.minX
precondition(wheel.handleWheelEvent(event) && zoomValues.count == 1 &&
             scroll.contentView.bounds.minX > beforeHorizontalRestart,
             "horizontal motion after a zero-delta begin cannot inherit the previous vertical axis")
event.gesturePhase = .ended; event.horizontalDelta = 0
precondition(wheel.handleWheelEvent(event))
event.gesturePhase = []; event.momentum = .began; event.horizontalDelta = -1
event.inputTime += 1.0 / 60
let beforeHorizontalMomentum = scroll.contentView.bounds.minX
precondition(wheel.handleWheelEvent(event) && zoomValues.count == 1 &&
             scroll.contentView.bounds.minX > beforeHorizontalMomentum,
             "native momentum continues on the axis of its own gesture")
event.momentum = .ended; event.horizontalDelta = 0
precondition(wheel.handleWheelEvent(event))
event.momentum = []; event.gesturePhase = .began; event.inputTime += 1.0 / 60
precondition(wheel.handleWheelEvent(event))
event.gesturePhase = .changed; event.delta = 0.1; event.inputTime += 1.0 / 60
precondition(wheel.handleWheelEvent(event) && zoomValues.count == 2,
             "a finished horizontal momentum tail cannot capture the next vertical gesture")
print("TRACKPAD_ZERO_BEGIN_AXIS_SWITCH_AND_MOMENTUM_OK")

resetZoomInput()
wheel.acceptRenderedZoom(TimelineZoomLimits.maximum)
scroll.contentView.scroll(to: .zero)
event.delta = 10
precondition(wheel.handleWheelEvent(event))
precondition(abs(scroll.contentView.bounds.midX - document.frame.width * wheel.position) < 1,
             "a new zoom gesture first centers the cursor even at the zoom limit")
precondition(zoomValues.isEmpty, "centering at the limit must not invent a scale change")

// A new gesture can precede the pending hosting update. The old pixel
// cursor must not become a different musical anchor at the new document size.
resetZoomInput()
wheel.cursorX = document.frame.width * 0.125
wheel.position = 0.5
wheel.modelUnitWidth = 12_345.25
event.delta = 2
let savedCallback = wheel.changeZoom
let savedHorizontalCallback = wheel.horizontalOffsetChanged
let priorZoomOrigin = scroll.contentView.bounds.minX
let priorZoomWidth = document.frame.width
var oldScalePublications = 0
wheel.horizontalOffsetChanged = { _ in oldScalePublications += 1 }
wheel.changeZoom = { _, _ in }
precondition(wheel.handleWheelEvent(event))
precondition(abs((scroll.zoomAnchor?.fraction ?? -1) - 0.5) < 1e-12,
             "a stale pixel cursor must never shift the musical anchor on fast repeated zoom")
precondition(scroll.contentView.bounds.minX == priorZoomOrigin && oldScalePublications == 0,
             "a real scale change must not prepare or expose an intermediate old-scale viewport")
precondition(abs((scroll.zoomAnchor?.width ?? -1) - 12_345.25 * wheel.zoom) < 1e-8,
             "a pending native frame must not change the model's target document width")
document.setFrameSize(NSSize(width: scroll.zoomAnchor!.width, height: 300))
scroll.applyZoomAnchor()
precondition(abs(scroll.contentView.bounds.midX - document.frame.width * 0.5) < 1e-7,
             "the first committed zoom layout centers the stable musical position")
document.setFrameSize(NSSize(width: priorZoomWidth, height: 300))
wheel.changeZoom = savedCallback
wheel.horizontalOffsetChanged = savedHorizontalCallback
wheel.cursorX = nil
wheel.modelUnitWidth = nil
print("ZOOM_STALE_CURSOR_PIXELS_DO_NOT_SHIFT_ANCHOR_OK")

resetZoomInput()
event.delta = 10
let initialLogResponse = 10 * TimelineZoomLimits.preciseSensitivity
let firstTrackpadInput = ProcessInfo.processInfo.systemUptime
precondition(wheel.handleWheelEvent(event))
precondition(zoomValues.count == 1,"the first trackpad zoom callback occurs before the event handler returns")
precondition(abs(zoomValues[0] - exp(initialLogResponse)) < 1e-10,"the first input applies its full delta without interpolation lag")
precondition(zoomTimes[0] >= firstTrackpadInput)
event.gesturePhase = .changed
let burstInput = ProcessInfo.processInfo.systemUptime
for delta: CGFloat in [3,4,5] {
    event.delta = delta; event.inputTime += 1.0 / 120
    precondition(wheel.handleWheelEvent(event))
}
precondition(zoomValues.count == 1,"a burst of trackpad input coalesces instead of laying out on each event")
requireZoomFrame(after: burstInput,callbackCount: 2)
let burstLogResponse = log(zoomValues.last!)
precondition(burstLogResponse >= 22 * TimelineZoomLimits.preciseSensitivity - 1e-12 && burstLogResponse <= 22 * TimelineZoomLimits.preciseSensitivity * 1.12 + 1e-12,
             "the next frame consumes the complete signed burst within the bounded velocity gain")
let finalBurstZoom = zoomValues.last!
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
precondition(zoomValues.count == 2 && zoomValues.last! == finalBurstZoom,
             "releasing the trackpad without native momentum adds no movement")

resetZoomInput(precise: false)
let savedBeforeWheel = TimelineViewportPreferences.storage.double(forKey: "jaras.timelineZoom")
event.delta = 2
let physicalStart = ProcessInfo.processInfo.systemUptime
precondition(wheel.handleWheelEvent(event))
precondition(TimelineViewportPreferences.storage.double(forKey: "jaras.timelineZoom") == savedBeforeWheel,
             "wheel input must not publish UserDefaults changes during a grid frame")
let physicalTarget = exp(2 * TimelineZoomLimits.wheelSensitivity)
precondition(zoomValues.count == 1 && zoomValues[0] > 1 && zoomValues[0] < physicalTarget,
             "a physical wheel tick responds immediately and leaves a short visible finish")
let physicalFirstStep = zoomValues[0]
wheel.acceptRenderedZoom(1)
precondition(wheel.zoom == physicalFirstStep,
             "an older SwiftUI update cannot rewind the first mouse animation step")
requireWheelZoomTarget(physicalTarget, after: physicalStart)
precondition(zoomValues.count >= 2 && zoomValues.allSatisfy { $0 >= 1 && $0 <= physicalTarget },
             "mouse animation uses bounded intermediate scale publications")
requireMonotonicZoom(zoomValues, increasing: true)
let physicalSettledCount = zoomValues.count
RunLoop.main.run(until: Date().addingTimeInterval(0.6))
precondition(zoomValues.count == physicalSettledCount && abs(zoomValues.last! - physicalTarget) < 1e-12,
             "a physical tick ends at its exact input target")
precondition(abs(TimelineViewportPreferences.storage.double(forKey: "jaras.timelineZoom") - zoomValues.last!) < 1e-12,
             "the final zoom preference is persisted after the gesture settles")
let physicalTailCount = zoomValues.count
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
precondition(zoomValues.count == physicalTailCount, "physical-wheel zoom settles without idle updates")
resetZoomInput(precise: false)
event.delta = 2
precondition(wheel.handleWheelEvent(event))
RunLoop.main.run(until: Date().addingTimeInterval(0.03))
let beforeReverse = zoomValues.last!
let beforeReverseCount = zoomValues.count
event.delta = -1; event.inputTime += 0.03
let mouseReversalStart = ProcessInfo.processInfo.systemUptime
precondition(wheel.handleWheelEvent(event))
let reverseTarget = beforeReverse * exp(-TimelineZoomLimits.wheelSensitivity)
requireWheelZoomTarget(reverseTarget, after: mouseReversalStart)
requireMonotonicZoom([beforeReverse] + Array(zoomValues.dropFirst(beforeReverseCount)), increasing: false)
let mouseReversalSettledCount = zoomValues.count
RunLoop.main.run(until: Date().addingTimeInterval(0.10))
precondition(zoomValues.count == mouseReversalSettledCount,
             "mouse reversal drops the unseen forward tail and ends at the reverse input target")

resetZoomInput(precise: false)
event.delta = 2
precondition(wheel.handleWheelEvent(event))
for _ in 0..<40 {
    // Small follow-up deltas remain below the velocity-gain threshold.
    event.delta = 0.02; event.inputTime += 1.0 / 120
    precondition(wheel.handleWheelEvent(event))
}
precondition(zoomValues.count == 1, "retargeting a mouse burst keeps layout at the display cadence")
let mouseBurstEnd = ProcessInfo.processInfo.systemUptime
requireWheelZoomTarget(exp(2.8 * TimelineZoomLimits.wheelSensitivity), after: mouseBurstEnd)
requireMonotonicZoom(zoomValues, increasing: true)

for phase: NSEvent.Phase in [[], .began] {
    resetZoomInput(precise: false)
    event.delta = 2
    precondition(wheel.handleWheelEvent(event))
    let switchBase = zoomValues.last!, switchCount = zoomValues.count
    event.precise = true; event.gesturePhase = phase; event.delta = -1; event.inputTime += 0.01
    let mouseToPreciseStart = ProcessInfo.processInfo.systemUptime
    precondition(wheel.handleWheelEvent(event))
    requireWheelZoomTarget(switchBase * exp(-TimelineZoomLimits.preciseSensitivity), after: mouseToPreciseStart)
    requireMonotonicZoom([switchBase] + Array(zoomValues.dropFirst(switchCount)), increasing: false)
    let switchSettledCount = zoomValues.count
    RunLoop.main.run(until: Date().addingTimeInterval(0.10))
    precondition(zoomValues.count == switchSettledCount, "precise input cancels the previous mouse animation")
}

for cancellation in ["modal", "held-pan"] {
    resetZoomInput(precise: false)
    event.delta = 2
    precondition(wheel.handleWheelEvent(event))
    let cancelledScale = zoomValues.last!, cancelledCount = zoomValues.count
    if cancellation == "modal" { gate.setBlocked(true, for: window) }
    else {
        event.delta = -1; event.inputTime += 0.01
        precondition(wheel.handleWheelEvent(event, pressedMouseButtons: 1))
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.12))
    precondition(zoomValues.count == cancelledCount && wheel.zoom == cancelledScale,
                 "\(cancellation) cancels every remaining mouse zoom animation frame")
}
resetZoomInput()
event.gesturePhase = []; event.delta = 2
precondition(wheel.handleWheelEvent(event))
precondition(zoomValues.count == 1 && abs(zoomValues[0] - exp(2 * TimelineZoomLimits.preciseSensitivity)) < 1e-12,
             "a precise mouse event without gesture phases is immediate too")
RunLoop.main.run(until: Date().addingTimeInterval(0.12))
precondition(zoomValues.count == 1)
print("MOUSE_ZOOM_RELEASE_ANIMATION_REVERSAL_AND_STALE_UPDATE_PROTECTION_OK")

// Holding the left button converts only an unmodified physical wheel into pan.
// A pending trackpad zoom/anchor is cancelled before the viewport moves.
resetZoomInput()
event.delta = 8
precondition(wheel.handleWheelEvent(event))
event.gesturePhase = .changed; event.delta = 12
precondition(wheel.handleWheelEvent(event))
scroll.zoomAnchor = (0.5, 200, 8000)
scroll.contentView.scroll(to: NSPoint(x: 500, y: 0))
event.precise = false; event.gesturePhase = []; event.delta = -2; event.inputTime += 1
let zoomBeforeHeldPan = zoomValues.count
precondition(wheel.handleWheelEvent(event, pressedMouseButtons: 1))
let panStep = scroll.contentView.bounds.minX
precondition(panStep == 536 && scroll.zoomAnchor == nil && zoomValues.count == zoomBeforeHeldPan,
             "left-held physical wheel pans immediately and discards a pending zoom anchor")
RunLoop.main.run(until: Date().addingTimeInterval(0.55))
precondition(scroll.contentView.bounds.minX == panStep &&
             zoomValues.count == zoomBeforeHeldPan, "physical pan adds no movement after release")
let settledPan = scroll.contentView.bounds.minX
RunLoop.main.run(until: Date().addingTimeInterval(0.06))
precondition(scroll.contentView.bounds.minX == settledPan, "physical pan adds no idle frames after settling")

event.delta = -2; event.inputTime += 1
precondition(wheel.handleWheelEvent(event, pressedMouseButtons: 1))
event.delta = 2; event.inputTime += 1.0 / 60
let beforePanReversal = scroll.contentView.bounds.minX
precondition(wheel.handleWheelEvent(event, pressedMouseButtons: 1))
precondition(scroll.contentView.bounds.minX < beforePanReversal, "reversal cancels the old pan tail in the same event")
let panReversalStep = scroll.contentView.bounds.minX
RunLoop.main.run(until: Date().addingTimeInterval(0.15))
precondition(scroll.contentView.bounds.minX == panReversalStep, "pan reversal ends at its input target")
event.modifiers = .command; event.inputTime += 1
let heldHeightCount = heights.count, heldOffset = scroll.contentView.bounds.minX
precondition(wheel.handleWheelEvent(event, pressedMouseButtons: 1) && heights.count == heldHeightCount + 1 &&
             scroll.contentView.bounds.minX == heldOffset, "Cmd plus held-left wheel retains track-height priority")
resetZoomInput(precise: false); event.delta = 1
precondition(wheel.handleWheelEvent(event, pressedMouseButtons: 2) && zoomValues.count == 1,
             "the right mouse button cannot activate held-left panning")
resetZoomInput(); event.delta = 1
precondition(wheel.handleWheelEvent(event, pressedMouseButtons: 1) && zoomValues.count == 1,
             "pressing the trackpad cannot turn its vertical zoom gesture into physical-wheel pan")
resetZoomInput(precise: false)
event.modifiers = .shift; event.delta = -2; event.inputTime += 1
scroll.contentView.scroll(to: NSPoint(x: 500, y: 0))
precondition(wheel.handleWheelEvent(event, pressedMouseButtons: 0) && scroll.contentView.bounds.minX == 608,
             "Shift applies the physical horizontal step immediately")
RunLoop.main.run(until: Date().addingTimeInterval(0.15))
precondition(scroll.contentView.bounds.minX == 608 && zoomValues.isEmpty, "Shift physical-wheel pan adds no synthetic coast")
event.inputTime += 1
precondition(wheel.handleWheelEvent(event, pressedMouseButtons: 0))
let beforePanModal = scroll.contentView.bounds.minX
gate.setBlocked(true, for: window)
RunLoop.main.run(until: Date().addingTimeInterval(0.12))
precondition(scroll.contentView.bounds.minX == beforePanModal, "opening an editor cancels physical pan inertia immediately")
gate.setBlocked(false, for: window)
event.inputTime += 1
precondition(wheel.handleWheelEvent(event, pressedMouseButtons: 0))
let sheetPan = scroll.contentView.bounds.minX
let nativeSheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
nativeSheet.isReleasedWhenClosed = false
window.beginSheet(nativeSheet)
RunLoop.main.run(until: Date().addingTimeInterval(0.12))
precondition(scroll.contentView.bounds.minX == sheetPan, "a native sheet outside the timeline gate also stops pan inertia")
window.endSheet(nativeSheet); nativeSheet.orderOut(nil)
print("HELD_LEFT_PHYSICAL_WHEEL_PAN_PRIORITY_REVERSAL_AND_SHORT_COAST_OK")

// The pending zoom layout cannot reclaim an explicit horizontal gesture or
// navigation. All destinations deliberately remain in the pre-zoom bucket:
// this also catches stale deduplication after changeZoom publishes a new one.
let previousZoomCallback = wheel.changeZoom
let previousOffsetCallback = wheel.horizontalOffsetChanged
var preparedHorizontalBucket: CGFloat = -1
wheel.observeHorizontalScroll()
wheel.horizontalOffsetChanged = { preparedHorizontalBucket = $0 }
wheel.changeZoom = { next, offset in
    zoomValues.append(next)
    preparedHorizontalBucket = floor(offset / 512) * 512
}
func beginPendingHorizontalZoom() -> CGFloat {
    resetZoomInput(precise: false)
    document.setFrameSize(NSSize(width: 4000, height: 300))
    wheel.position = 1300.0 / 4000.0
    wheel.modelUnitWidth = 4000
    scroll.contentView.scroll(to: NSPoint(x: 1100, y: 0))
    event.delta = CGFloat(log(8) / TimelineZoomLimits.wheelSensitivity)
    precondition(wheel.handleWheelEvent(event, pressedMouseButtons: 0))
    precondition(scroll.zoomAnchor != nil && preparedHorizontalBucket > 1536,
                 "the first mouse animation step prepares a bucket beyond the old viewport")
    return scroll.zoomAnchor!.width
}
for mode in ["shift", "trackpad", "focus"] {
    let targetWidth = beginPendingHorizontalZoom()
    // Keep another input waiting for a display frame. Taking horizontal control
    // must stop this request as well as discard the already-published anchor.
    event.delta = 0.2; event.inputTime += 1.0 / 120
    precondition(wheel.handleWheelEvent(event, pressedMouseButtons: 0))
    let updates = zoomValues.count
    if mode == "focus" {
        wheel.focus(request: UUID(), x: 1450)
    } else {
        event.inputTime += 1
        if mode == "shift" {
            event.modifiers = .shift; event.delta = -2
        } else {
            event.precise = true; event.gesturePhase = .began
            event.delta = 0; event.horizontalDelta = -30
        }
        precondition(wheel.handleWheelEvent(event, pressedMouseButtons: 0))
    }
    let destination = scroll.contentView.bounds.minX
    precondition(destination > 1100 && destination < 1536 && scroll.zoomAnchor == nil,
                 "\(mode) takes horizontal ownership before a pending zoom layout")
    precondition(preparedHorizontalBucket == 1024,
                 "\(mode) prepares the old bucket again in the same input event")
    document.setFrameSize(NSSize(width: targetWidth, height: 300))
    scroll.applyZoomAnchor()
    RunLoop.main.run(until: Date().addingTimeInterval(0.025))
    precondition(scroll.contentView.bounds.minX == destination && zoomValues.count == updates,
                 "\(mode) cannot be recentered by the old anchor or a queued zoom frame")
}
let committedZoomWidth = beginPendingHorizontalZoom()
document.setFrameSize(NSSize(width: committedZoomWidth, height: 300))
scroll.applyZoomAnchor()
precondition(scroll.zoomAnchor == nil && preparedHorizontalBucket > 1536)
scroll.contentView.scroll(to: NSPoint(x: 1100, y: 0))
precondition(preparedHorizontalBucket == 1024,
             "native pan back to the pre-zoom bucket must republish after a committed zoom")
resetZoomInput()
wheel.modelUnitWidth = nil
wheel.changeZoom = previousZoomCallback
wheel.horizontalOffsetChanged = previousOffsetCallback
document.setFrameSize(NSSize(width: 4000, height: 300))
print("PENDING_ZOOM_SHIFT_TRACKPAD_FOCUS_OWNERSHIP_AND_BUCKET_RETURN_OK")

// A pending newer scale must not prevent centering an intermediate frame.
scroll.zoomAnchor = (0.5, 200, 8000)
document.setFrameSize(NSSize(width: 6000, height: 300))
scroll.applyZoomAnchor()
precondition(abs(scroll.contentView.bounds.minX - 2800) < 1 && scroll.zoomAnchor?.width == 8000,
             "an intermediate layout centers its actual scale and retains the newer target")
document.setFrameSize(NSSize(width: 8000, height: 300))
scroll.applyZoomAnchor()
precondition(abs(scroll.contentView.bounds.minX - 3800) < 1 && scroll.zoomAnchor == nil,
             "the final layout centers and acknowledges the requested scale")

// Reproduce tiny zoom changes at 37:51: an old host layout less than two
// points from its target must not discard the pending fractional anchor.
let farPosition = 37.0 * 60 + 51
let farFraction = farPosition / 6000
var previousWidth = 60000.0
for delta in [0.125, 0.375, 0.75, -0.25, -0.875, 0.5, 0.0625] {
    let targetWidth = previousWidth + delta
    document.setFrameSize(NSSize(width: previousWidth, height: 300))
    scroll.zoomAnchor = (farFraction, 200, targetWidth)
    scroll.applyZoomAnchor()
    precondition(scroll.zoomAnchor != nil,
                 "an intermediate layout inside the old two-point tolerance must retain its target")
    document.setFrameSize(NSSize(width: targetWidth, height: 300))
    scroll.applyZoomAnchor()
    precondition(scroll.zoomAnchor == nil && abs(targetWidth * farFraction - scroll.contentView.bounds.minX - 200) < 1e-7,
                 "the final fractional scale and viewport keep the far-position needle at exactly the same screen point")
    previousWidth = targetWidth
}
print("FRACTIONAL_ZOOM_37M51S_DELAYED_LAYOUT_ANCHOR_HAS_NO_ALTERNATING_PIXEL_ERROR_OK")
document.setFrameSize(NSSize(width: 4000, height: 300))

resetZoomInput()
event.delta = 8
precondition(wheel.handleWheelEvent(event))
event.gesturePhase = .changed
let reversalInput = ProcessInfo.processInfo.systemUptime
for delta: CGFloat in [12,-30] { event.delta = delta; precondition(wheel.handleWheelEvent(event)) }
precondition(zoomValues.count == 1)
requireZoomFrame(after: reversalInput,callbackCount: 2)
precondition(zoomValues.last! < zoomValues[0],"reversing the fingers changes direction in the next display frame")
RunLoop.main.run(until: Date().addingTimeInterval(0.55))
precondition(zoomValues.last! < 1,"reversal preserves the total signed movement instead of queuing an animation")
let settledUpdates = zoomValues.count
RunLoop.main.run(until: Date().addingTimeInterval(0.035))
precondition(zoomValues.count == settledUpdates,"after settling, idle frames add no stale target callback")

resetZoomInput()
event.delta = 8
precondition(wheel.handleWheelEvent(event))
event.gesturePhase = []; event.momentum = .began
let fingerScale = zoomValues.last!
for delta: CGFloat in [4,2,1] {
    event.delta = delta
    precondition(wheel.handleWheelEvent(event))
    RunLoop.main.run(until: Date().addingTimeInterval(0.025))
    precondition(zoomValues.last! > fingerScale, "native trackpad momentum continues zoom after release")
    event.momentum = .changed
}
event.delta = 0; event.momentum = .ended
precondition(wheel.handleWheelEvent(event))
let nativeMomentumUpdates = zoomValues.count
RunLoop.main.run(until: Date().addingTimeInterval(0.035))
precondition(zoomValues.count == nativeMomentumUpdates,"native momentum has no added synthetic animation")

// Ending a gesture and beginning another before a display tick cannot lose
// the previous gesture's queued signed travel, including a zero-delta begin.
resetZoomInput()
event.delta = 0.1
precondition(wheel.handleWheelEvent(event))
event.gesturePhase = .changed; event.delta = 0.2; event.inputTime += 1.0 / 120
precondition(wheel.handleWheelEvent(event) && zoomValues.count == 1)
event.gesturePhase = .ended; event.delta = 0
precondition(wheel.handleWheelEvent(event))
event.gesturePhase = .began; event.inputTime += 1.0 / 120
precondition(wheel.handleWheelEvent(event))
precondition(zoomValues.count == 2 && abs(log(zoomValues.last!) - 0.3 * TimelineZoomLimits.preciseSensitivity) < 1e-12,
             "new zero-delta begin commits the preceding gesture's pending movement")
event.gesturePhase = .changed; event.delta = 0.1; event.inputTime += 1.0 / 120
precondition(wheel.handleWheelEvent(event) && zoomValues.count == 3)
precondition(abs(log(zoomValues.last!) - 0.4 * TimelineZoomLimits.preciseSensitivity) < 1e-12)

resetZoomInput(precise: false)
let preferenceBeforeDebounce = TimelineViewportPreferences.storage.double(forKey: "jaras.timelineZoom")
event.delta = 1
precondition(wheel.handleWheelEvent(event))
RunLoop.main.run(until: Date().addingTimeInterval(0.14))
event.inputTime += 0.14
precondition(wheel.handleWheelEvent(event))
RunLoop.main.run(until: Date().addingTimeInterval(0.24))
let latestDebouncedZoom = zoomValues.last!
precondition(TimelineViewportPreferences.storage.double(forKey: "jaras.timelineZoom") == preferenceBeforeDebounce,
             "new input cancels the previous burst's pending preference write")
RunLoop.main.run(until: Date().addingTimeInterval(0.20))
precondition(abs(TimelineViewportPreferences.storage.double(forKey: "jaras.timelineZoom") - latestDebouncedZoom) < 1e-12,
             "the final latest scale persists after the newest burst settles")
print("ZOOM_PENDING_GESTURE_TRAVEL_AND_PERSISTENCE_DEBOUNCE_OK")

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
var rulerFreeSeeks: [Bool] = []
ruler.seek = { _,_,free in seeks += 1; rulerFreeSeeks.append(free) }
func pointer(_ type: NSEvent.EventType) -> NSEvent {
    NSEvent.mouseEvent(with: type,location: ruler.convert(NSPoint(x: 100,y: 12),to: nil),modifierFlags: [],timestamp: ProcessInfo.processInfo.systemUptime,windowNumber: window.windowNumber,context: nil,eventNumber: 1,clickCount: 1,pressure: 1)!
}
ruler.rightMouseDown(with: pointer(.rightMouseDown))
precondition(seeks == 0)
gate.setBlocked(false,for: window)
ruler.mouseDown(with: pointer(.leftMouseDown))
event.modifiers = []; event.precise = false; event.gesturePhase = []; event.delta = -1
precondition(wheel.handleWheelEvent(event, pressedMouseButtons: 1))
ruler.mouseUp(with: pointer(.leftMouseUp))
precondition(seeks == 0, "held-left wheel pan cancels a pending ruler seek on release")
ruler.mouseDown(with: pointer(.leftMouseDown))
gate.setBlocked(true,for: window); gate.setBlocked(false,for: window)
ruler.mouseUp(with: pointer(.leftMouseUp))
precondition(seeks == 0, "native modal opening cancels a pending ruler press")
ruler.rightMouseDown(with: pointer(.rightMouseDown))
ruler.rightMouseUp(with: pointer(.rightMouseUp))
precondition(seeks == 1, "the ruler resumes immediately after closing the modal")
let shifted = NSEvent.mouseEvent(with: .leftMouseUp, location: ruler.convert(NSPoint(x: 113.75, y: 12),to: nil), modifierFlags: .shift, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
ruler.mouseDown(with: shifted); ruler.mouseUp(with: shifted)
precondition(rulerFreeSeeks.last == true, "Shift ruler clicks send a free-positioning request rather than grid snapping")
let seeksBeforeVerticalDrag = seeks
let verticalDrag = NSEvent.mouseEvent(with: .leftMouseDragged, location: ruler.convert(NSPoint(x: 100, y: 28), to: nil),
    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
    context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
ruler.mouseDown(with: pointer(.leftMouseDown))
precondition(seeks == seeksBeforeVerticalDrag, "ruler presses wait for release")
ruler.mouseDragged(with: verticalDrag)
ruler.mouseUp(with: pointer(.leftMouseUp))
precondition(seeks == seeksBeforeVerticalDrag, "a vertical ruler drag returning to its origin cannot seek")
print("RULER_PURE_RELEASE_ONLY_AND_VERTICAL_DRAG_NO_SEEK_OK")
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
    window.orderBack(nil)
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
let boundedScroll = GridNativeScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
boundedScroll.contentView = TimelineClipView()
boundedScroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
boundedScroll.contentView.scroll(to: NSPoint(x: 999, y: 999))
precondition(boundedScroll.contentView.bounds.minX <= 400 && boundedScroll.contentView.bounds.minY <= 200,
             "momentum scroll must not reveal background beyond either document edge")
boundedScroll.contentView.scroll(to: NSPoint(x: -100, y: -100))
precondition(boundedScroll.contentView.bounds.minX == 0 && boundedScroll.contentView.bounds.minY == 0,
             "scroll cannot bounce beyond the beginning of the timeline or track list")
print("GRID_SCROLL_BOUNDED_ON_BOTH_AXES_OK")
print("NATIVE_MODAL_GATE_IMMEDIATE_ZOOM_FRAME_COALESCING_REVERSAL_ZOOM_INERTIA_AND_CMD_CTRL_TRACK_HEIGHT_OK")

precondition(TimelineZoomLimits.minimum > 0 && TimelineZoomLimits.minimum < 0.02 && TimelineZoomLimits.maximum > 16, "distance stops at the chosen overview while proximity remains available")
let fullRange = log(TimelineZoomLimits.maximum / TimelineZoomLimits.minimum)
for sign in [-1.0, 1.0] {
    var response = TimelineZoomResponse(), movement = 0.0, amount = 0.0
    _ = response.change(delta: 0, timestamp: 10, begins: true)
    for index in 1...60 {
        amount += response.change(delta: sign * 10, timestamp: 10 + Double(index) / 120, begins: false)
        movement += 10
        if abs(amount) >= fullRange { break }
    }
    precondition(abs(amount) > movement * TimelineZoomLimits.preciseSensitivity && abs(amount) <= movement * TimelineZoomLimits.preciseSensitivity * 1.12,
                 "sustained faster movement receives modest bounded gain")
    let lastSwipeTime = 10 + movement / 1200
    let correction = response.change(delta: sign * 0.2, timestamp: lastSwipeTime + 0.01, begins: false)
    precondition(abs(correction) <= 0.002, "slowing down immediately restores fine control")
    let reversal = response.change(delta: -sign * 0.2, timestamp: lastSwipeTime + 0.02, begins: false)
    precondition(abs(reversal) <= 0.002, "a small reversal cannot inherit the previous swipe acceleration")
    print("FAST_ZOOM_FULL_RANGE_MOVEMENT=\(movement) FINE_CORRECTION=\(abs(correction))")
}
var slow = TimelineZoomResponse(), slowAmount = 0.0
_ = slow.change(delta: 0, timestamp: 20, begins: true)
for index in 1...500 { slowAmount += slow.change(delta: 0.2, timestamp: 20 + Double(index) / 60, begins: false) }
precondition(slowAmount < 1, "the same long travel at low speed must keep precision")
var totals: [Double] = []
for frequency in [60.0, 120.0, 240.0] {
    var response = TimelineZoomResponse(), total = 0.0
    _ = response.change(delta: 0, timestamp: 40, begins: true)
    for index in 1...Int(frequency / 5) {
        total += response.change(delta: 1800 / frequency, timestamp: 40 + Double(index) / frequency, begins: false)
    }
    totals.append(total)
}
precondition((totals.max()! - totals.min()!) / totals.min()! < 0.01, "splitting equal physical travel at 60/120/240Hz changes zoom travel by less than one percent")
print("ADAPTIVE_ZOOM_PRECISION_SPEED_REVERSAL_AND_EVENT_FREQUENCY_OK")
for tinyDelta in [0.0001, 0.1, 0.2, -0.0001, -0.1, -0.2] {
    var fine = TimelineZoomResponse(), total = 0.0
    for index in 0..<24 {
        let delta = index < 12 ? tinyDelta : -tinyDelta
        let amount = fine.change(delta: delta, timestamp: 50 + Double(index) / 60, begins: index == 0)
        precondition(abs(amount - delta * TimelineZoomLimits.preciseSensitivity) < 1e-14,
                     "every fractional event retains the configured fine sensitivity immediately")
        total += amount
    }
    precondition(abs(total) < 1e-14, "equal opposite fine movements cancel without losing a remainder")
}
var fine = TimelineZoomResponse()
_ = fine.change(delta: 0.1, timestamp: 60, begins: true)
var accelerated = false
for index in 1...20 {
    let amount = fine.change(delta: 10, timestamp: 60 + Double(index) / 120, begins: false)
    if amount > 10 * TimelineZoomLimits.preciseSensitivity { accelerated = true }
}
precondition(accelerated, "sustained fast input receives the requested bounded velocity response")
let fineAfterFast = fine.change(delta: -0.1, timestamp: 60.18, begins: false)
precondition(abs(fineAfterFast + 0.1 * TimelineZoomLimits.preciseSensitivity) < 1e-14,
             "a fine reversal responds immediately without inheriting fast-swipe acceleration")
print("ZOOM_CONTINUOUS_FINE_INPUT_AND_ACCELERATION_OK")

gate.setBlocked(false, for: window)
window.orderBack(nil)
var area = (0.25, 0.65)
var resizeRequests: [(Double, Bool)] = []
ruler.selectedTime = { area }
ruler.resizeTime = { fraction, left in
    resizeRequests.append((fraction,left))
    if left { area.0 = min(fraction, area.1) } else { area.1 = max(fraction, area.0) }
}
func areaPointer(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: ruler.convert(CGPoint(x: x,y: 12),to: nil),modifierFlags: [],timestamp: ProcessInfo.processInfo.systemUptime,windowNumber: window.windowNumber,context: nil,eventNumber: 1,clickCount: 1,pressure: 1)!
}
let oldIntervals = intervals.count
ruler.rightMouseDown(with: areaPointer(.rightMouseDown,x: 260))
ruler.rightMouseDragged(with: areaPointer(.rightMouseDragged,x: 300))
ruler.rightMouseUp(with: areaPointer(.rightMouseUp,x: 300))
precondition(area.0 == 0.25 && area.1 == 0.75 && intervals.count == oldIntervals, "right edge adjusts existing area without creating a new one")
ruler.mouseDown(with: areaPointer(.leftMouseDown,x: 100))
ruler.mouseDragged(with: areaPointer(.leftMouseDragged,x: 80))
ruler.mouseUp(with: areaPointer(.leftMouseUp,x: 80))
precondition(area.0 == 0.2 && area.1 == 0.75 && resizeRequests.last!.1, "left edge keeps right edge fixed")
ruler.mouseEntered(with: areaPointer(.leftMouseUp,x: 180))
precondition(NSCursor.current == NSCursor.openHand, "hand appears on entering ruler without a press")
ruler.markerCursor = { _ in true }
ruler.mouseMoved(with: areaPointer(.mouseMoved, x: 180))
precondition(NSCursor.current == NSCursor.resizeLeftRight, "ruler tracking cannot overwrite the tempo display move cursor")
ruler.markerCursor = { _ in false }
ruler.mouseMoved(with: areaPointer(.mouseMoved, x: 180))
precondition(NSCursor.current == NSCursor.openHand, "leaving the tempo display restores the ruler hand")
print("RULER_AREA_EXISTING_EDGES_AND_IMMEDIATE_HOVER_OK")

window.close()

for precise in [false, true] {
    func travel(speed: Double, frequency: Double) -> Double {
        var response = TimelineInputVelocityResponse(), total = 0.0
        _ = response.change(amount: 0, timestamp: 100, begins: true, precise: precise)
        for index in 1...Int(frequency) {
            let amount = speed / frequency
            let changed = response.change(amount: amount, timestamp: 100 + Double(index) / frequency, begins: false, precise: precise)
            precondition(changed >= amount && changed <= amount * (precise ? 1.12 : 1.4) + 1e-12)
            total += changed
        }
        return total / speed
    }
    let slowGain = travel(speed: 0.2, frequency: 120)
    let fastGain = travel(speed: 4, frequency: 120)
    precondition(abs(slowGain - 1) < 1e-10 && fastGain > slowGain + 0.05,
                 "gain follows real travel velocity rather than event count")
    let rates = [30.0, 60, 120, 240].map { travel(speed: 1.5, frequency: $0) }
    precondition((rates.max()! - rates.min()!) / rates.min()! < 0.01,
                 "equal motion subdivided into different event rates keeps approximately equal gain")
    var response = TimelineInputVelocityResponse()
    _ = response.change(amount: 0, timestamp: 200, begins: true, precise: precise)
    for index in 1...30 { _ = response.change(amount: 0.04, timestamp: 200 + Double(index) / 120, begins: false, precise: precise) }
    let fineCorrection = response.change(amount: 0.0001, timestamp: 200.26, begins: false, precise: precise)
    let reversal = response.change(amount: -0.0001, timestamp: 200.27, begins: false, precise: precise)
    precondition(fineCorrection == 0.0001 && reversal == -0.0001,
                 "deceleration and reversal immediately restore fine control")
    precondition(response.change(amount: 0.1, timestamp: 200.27, begins: false, precise: precise) == 0.1,
                 "identical timestamps cannot create artificial acceleration")
    precondition(response.change(amount: 0.1, timestamp: 201, begins: false, precise: precise) == 0.1,
                 "a new burst after idle starts at the native sensitivity")
    precondition(response.change(amount: .nan, timestamp: 201.01, begins: false, precise: precise) == 0)
    print("INPUT_VELOCITY_TRAVEL_FREQUENCY_FINE_REVERSAL_OK precise=\(precise) slow=\(slowGain) fast=\(fastGain) rateGains=\(rates)")
}

precondition((UserDefaults.standard.object(forKey: "jaras.timelineZoom") as? NSObject) == legacyZoomBeforeTest,
             "zoom persistence must never write the standard preferences domain")
print("ZOOM_PERSISTENCE_LEAVES_STANDARD_PREFERENCES_UNCHANGED_OK")
