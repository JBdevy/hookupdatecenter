import AppKit
let input = TimelineTrackHeightInput.height
let first = input(64, exp(0.2))
precondition(abs(first - (64 + 12.8)) < 0.00001, "A wheel event immediately applies its complete travel")
precondition(abs(input(first, exp(-0.2)) - 64) < 0.00001, "Reversal has no pending animation to consume")
var burst: CGFloat = 64
for _ in 0..<4 { burst = input(burst, exp(0.2)) }
precondition(abs(burst - (64 + 51.2)) < 0.00001)
precondition(input(200, 10) == TimelineTrackHeightLimits.maximum)
precondition(input(60, 0.01) == TimelineTrackHeightLimits.minimum)
precondition(input(64, .nan) == 64 && input(64, .infinity) == 64 && input(64, -1) == 64)
precondition(input(64, 1.001) > 64 && input(64, 1.001) < 65, "Trackpad keeps fractional heights")
print("TRACK_HEIGHT_DIRECT_INPUT_OK immediate travel, reversal, bounds, fractional heights")

let motion = TimelineTrackHeightMotion()
var values: [CGFloat] = []
var expected: CGFloat = 100
func delta(_ factor: Double) {
    expected = input(expected, factor)
    // Simulate SwiftUI closures still holding the height from the previous frame.
    motion.change(factor: factor, current: 100) { values.append($0) }
}
delta(exp(0.05))
precondition(values.count == 1 && abs(values[0] - expected.rounded()) < 0.00001,
             "The first event must reach the screen immediately")
for _ in 0..<120 { delta(exp(0.002)) }
for _ in 0..<75 { delta(exp(-0.002)) }
precondition(values.count == 1, "A burst must not queue hundreds of expensive layout passes")
RunLoop.main.run(until: Date().addingTimeInterval(0.04))
precondition(values.count == 2 && abs(values.last! - expected.rounded()) < 0.00001,
             "One frame must consume every delta, including immediate direction reversal")
let afterFrame = values.count
RunLoop.main.run(until: Date().addingTimeInterval(0.11))
precondition(values.count == afterFrame, "No interpolation or duplicate geometry after input ends")

motion.change(factor: exp(0.02), current: 160) { values.append($0) }
precondition(abs(values.last! - input(160, exp(0.02)).rounded()) < 0.00001,
             "A new gesture must use the current height, not the previous gesture")
motion.change(factor: exp(0.10), current: 160) { values.append($0) }
let beforeCancel = values.count
motion.cancel()
RunLoop.main.run(until: Date().addingTimeInterval(0.04))
precondition(values.count == beforeCancel, "Closing or blocking the grid cancels pending layout")
print("TRACK_HEIGHT_FRAME_BATCHING_OK first response, 196 deltas, exact reversal, idle, cancel")

let fineMotion = TimelineTrackHeightMotion()
var fineHeight: CGFloat = 64
var fineUpdates = 0
func fineDelta(_ points: Double) {
    fineMotion.change(factor: exp(points / 64), current: fineHeight) { fineHeight = $0; fineUpdates += 1 }
}
fineDelta(0.2)
precondition(fineHeight == 64 && fineUpdates == 0, "sub-point input accumulates without publishing fractional geometry")
RunLoop.main.run(until: Date().addingTimeInterval(0.10))
fineDelta(0.2); fineDelta(0.2)
precondition(fineHeight == 65 && fineUpdates == 1, "short idle cannot discard fractional wheel travel")
RunLoop.main.run(until: Date().addingTimeInterval(0.11))
fineDelta(-0.2)
precondition(fineHeight == 64, "a reversal consumes the retained signed remainder immediately")
for _ in 0..<3 { fineDelta(0.2) }
RunLoop.main.run(until: Date().addingTimeInterval(0.04))
precondition(fineHeight == 65, "repeated fractional events accumulate to their exact rounded total")
let settledCount = fineUpdates
RunLoop.main.run(until: Date().addingTimeInterval(0.12))
precondition(fineUpdates == settledCount, "idle never manufactures extra geometry")
fineMotion.cancel()
fineHeight = 239
fineDelta(20)
precondition(fineHeight == 240)
fineDelta(-1)
RunLoop.main.run(until: Date().addingTimeInterval(0.04))
precondition(fineHeight == 239, "the clamp drops excess remainder so reversing leaves the maximum immediately")
fineMotion.cancel(); fineHeight = 25
fineDelta(-20); fineDelta(1)
RunLoop.main.run(until: Date().addingTimeInterval(0.04))
precondition(fineHeight == 25, "the minimum clamp cannot retain a hidden negative tail")
fineMotion.cancel(); fineHeight = 64
fineDelta(0.4); fineMotion.cancel(); fineDelta(0.2)
precondition(fineHeight == 64, "real cancellation clears pending fractions")
fineMotion.cancel()
print("TRACK_HEIGHT_INTEGER_GEOMETRY_REMAINDER_IDLE_REVERSAL_AND_CLAMP_OK")

for precise in [false, true] {
    let sensitivity = precise ? TimelineTrackHeightLimits.preciseSensitivity : TimelineTrackHeightLimits.wheelSensitivity
    var totals: [Double] = []
    for frequency in [30.0, 60, 120, 240] {
        var response = TimelineTrackHeightResponse(), travel = 0.0
        _ = response.factor(delta: 0, timestamp: 10, begins: true, precise: precise)
        for index in 1...Int(frequency / 2) {
            let factor = response.factor(delta: 1.5 / (frequency * sensitivity),
                timestamp: 10 + Double(index) / frequency, begins: false, precise: precise)
            precondition(factor >= 1 && log(factor) <= TimelineTrackHeightLimits.maximumWheelStep)
            travel += log(factor)
        }
        totals.append(travel)
        let reverse = response.factor(delta: -0.001 / sensitivity, timestamp: 10.51, begins: false, precise: precise)
        precondition(abs(log(reverse) + 0.001) < 1e-12, "height reversal immediately uses its own signed travel")
    }
    precondition((totals.max()! - totals.min()!) / totals.min()! < 0.01,
                 "height velocity response follows travel/time, not event frequency")
}
print("TRACK_HEIGHT_VELOCITY_GAIN_EVENT_SPLITTING_AND_FINE_REVERSAL_OK")


// A wheel notch has a visible first response before returning, followed by a
// bounded transition. Time is wall-clock based so a late frame finishes rather
// than stretching the animation indefinitely.
func waitForHeight(_ target: CGFloat, values: () -> [CGFloat], since start: Double) {
    // Allow the 65 ms transition and the next native display tick.
    let deadline = start + 0.100
    while values().last != target && ProcessInfo.processInfo.systemUptime < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
    }
    precondition(values().last == target, "wheel smoothing reaches the exact target within 100 ms")
    precondition(ProcessInfo.processInfo.systemUptime - start < 0.100,
                 "a short visual transition cannot turn into input latency")
}
func requireMonotonic(_ values: [CGFloat], increasing: Bool) {
    for (previous, next) in zip(values, values.dropFirst()) {
        precondition(increasing ? next >= previous : next <= previous,
                     "a short wheel transition cannot overshoot or resume an old direction")
    }
}
let smoothMotion = TimelineTrackHeightMotion()
var smoothValues: [CGFloat] = []
let smoothStart = ProcessInfo.processInfo.systemUptime
smoothMotion.change(factor: exp(20.0 / 64), current: 100, smoothWheel: true) { smoothValues.append($0) }
precondition(smoothValues.count == 1 && smoothValues[0] > 100 && smoothValues[0] < 120,
             "a discrete notch responds immediately with partial travel")
waitForHeight(120, values: { smoothValues }, since: smoothStart)
precondition(smoothValues.count >= 2 && smoothValues.allSatisfy { $0 >= 100 && $0 <= 120 })
requireMonotonic(smoothValues, increasing: true)
let smoothSettled = smoothValues.count
RunLoop.main.run(until: Date().addingTimeInterval(0.10))
precondition(smoothValues.count == smoothSettled, "a settled notch has no duplicate publication or animation tail")
// After its idle timer expires, another control may have changed the height.
// New animation must start from that external value, not the old 120-point row.
let externalStart = ProcessInfo.processInfo.systemUptime
let externalIndex = smoothValues.count
smoothMotion.change(factor: exp(10.0 / 64), current: 180, smoothWheel: true) { smoothValues.append($0) }
precondition(smoothValues.count == externalIndex + 1 && smoothValues.last! > 180 && smoothValues.last! < 190,
             "an external idle height resets the animation's presented starting value")
waitForHeight(190, values: { smoothValues }, since: externalStart)
smoothMotion.cancel()
print("TRACK_HEIGHT_WHEEL_PARTIAL_IMMEDIATE_EXACT_SHORT_SETTLE_AND_EXTERNAL_HEIGHT_OK")

let smoothBurstMotion = TimelineTrackHeightMotion()
var smoothBurstValues: [CGFloat] = []
let smoothBurstStart = ProcessInfo.processInfo.systemUptime
smoothBurstMotion.change(factor: exp(12.0 / 64), current: 100, smoothWheel: true) { smoothBurstValues.append($0) }
for _ in 0..<40 {
    // A real SwiftUI callback may still capture the pre-frame height. Accumulate
    // every delta internally while the presentation remains frame-batched.
    smoothBurstMotion.change(factor: exp(0.5 / 64), current: 100, smoothWheel: true) { smoothBurstValues.append($0) }
}
precondition(smoothBurstValues.count == 1, "wheel retargeting must not publish one layout per input event")
waitForHeight(132, values: { smoothBurstValues }, since: smoothBurstStart)
requireMonotonic(smoothBurstValues, increasing: true)
smoothBurstMotion.cancel()
print("TRACK_HEIGHT_WHEEL_BURST_ACCUMULATES_COMPLETE_TRAVEL_AND_BATCHES_OK")

let reverseMotion = TimelineTrackHeightMotion()
var reverseValues: [CGFloat] = []
reverseMotion.change(factor: exp(20.0 / 64), current: 100, smoothWheel: true) { reverseValues.append($0) }
let reversalBase = reverseValues.last!
let beforeReversalCount = reverseValues.count
let reverseStart = ProcessInfo.processInfo.systemUptime
reverseMotion.change(factor: exp(-8.0 / 64), current: 100, smoothWheel: true) { reverseValues.append($0) }
waitForHeight(reversalBase - 8, values: { reverseValues }, since: reverseStart)
let reversedPresentation = [reversalBase] + Array(reverseValues.dropFirst(beforeReversalCount))
requireMonotonic(reversedPresentation, increasing: false)
precondition(reverseValues.last == reversalBase - 8,
             "reversing drops only unpresented animation travel and uses the visible height")
reverseMotion.cancel()
print("TRACK_HEIGHT_WHEEL_REVERSAL_DROPS_OLD_VISUAL_TAIL_OK")

let directMotion = TimelineTrackHeightMotion()
var directValues: [CGFloat] = []
directMotion.change(factor: exp(20.0 / 64), current: 100, smoothWheel: false) { directValues.append($0) }
precondition(directValues == [120], "trackpad still publishes its complete first delta synchronously")
RunLoop.main.run(until: Date().addingTimeInterval(0.10))
precondition(directValues == [120], "trackpad gains no interpolation frames")
directMotion.cancel()
var switchedValues: [CGFloat] = []
directMotion.change(factor: exp(20.0 / 64), current: 100, smoothWheel: true) { switchedValues.append($0) }
let switchBase = switchedValues.last!
let switchStart = ProcessInfo.processInfo.systemUptime
directMotion.change(factor: exp(-3.0 / 64), current: 100, smoothWheel: false) { switchedValues.append($0) }
waitForHeight(switchBase - 3, values: { switchedValues }, since: switchStart)
requireMonotonic([switchBase] + Array(switchedValues.dropFirst()), increasing: false)
let afterSwitch = switchedValues.count
RunLoop.main.run(until: Date().addingTimeInterval(0.10))
precondition(switchedValues.count == afterSwitch, "precise input cancels the previous wheel transition")
directMotion.cancel()
print("TRACK_HEIGHT_PRECISE_INPUT_UNCHANGED_AND_CANCELS_WHEEL_TRANSITION_OK")

for sign in [-1.0, 1.0] {
    let limitMotion = TimelineTrackHeightMotion()
    var limitValues: [CGFloat] = []
    let limitStart = ProcessInfo.processInfo.systemUptime
    for _ in 0..<20 {
        limitMotion.change(factor: exp(sign * TimelineTrackHeightLimits.maximumWheelStep),
                           current: 64, smoothWheel: true) { limitValues.append($0) }
    }
    let limit = sign > 0 ? TimelineTrackHeightLimits.maximum : TimelineTrackHeightLimits.minimum
    waitForHeight(limit, values: { limitValues }, since: limitStart)
    requireMonotonic(limitValues, increasing: sign > 0)
    precondition(limitValues.allSatisfy { $0 >= TimelineTrackHeightLimits.minimum && $0 <= TimelineTrackHeightLimits.maximum },
                 "the animated full course stays within the same hard bounds")
    limitMotion.cancel()
}
let cancelledWheel = TimelineTrackHeightMotion()
var cancelledValues: [CGFloat] = []
cancelledWheel.change(factor: exp(20.0 / 64), current: 100, smoothWheel: true) { cancelledValues.append($0) }
let beforeWheelCancel = cancelledValues.count
cancelledWheel.cancel()
RunLoop.main.run(until: Date().addingTimeInterval(0.10))
precondition(cancelledValues.count == beforeWheelCancel, "modal or teardown cancellation discards pending animation frames")
cancelledWheel.change(factor: exp(1.0 / 64), current: 80, smoothWheel: true) { cancelledValues.append($0) }
precondition(cancelledValues.last == 81, "a sub-two-point correction stays direct and starts at the new height")
cancelledWheel.cancel()
print("TRACK_HEIGHT_WHEEL_FULL_RANGE_BOUNDS_CANCEL_AND_SMALL_CORRECTION_OK")

// Exercise each supported modifier and both directions with native event data.
_ = NSApplication.shared
let heightWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
heightWindow.isReleasedWhenClosed = false
let wheelView = TimelineMixerHeightWheelView(frame: CGRect(x: 0, y: 0, width: 240, height: 100))
heightWindow.contentView = wheelView
var wheelPublications = 0
var wheelFactors: [Double] = [], wheelSmoothing: [Bool] = []
wheelView.change = { factor, smooth in
    wheelPublications += 1; wheelFactors.append(factor); wheelSmoothing.append(smooth)
}
final class HeightWheelFixtureEvent: NSEvent {
    weak var fixtureWindow: NSWindow?
    var flags: NSEvent.ModifierFlags = []
    var point = CGPoint.zero
    var delta: CGFloat = 1
    var precise = false
    override var window: NSWindow? { fixtureWindow }
    override var type: NSEvent.EventType { .scrollWheel }
    override var locationInWindow: NSPoint { point }
    override var modifierFlags: NSEvent.ModifierFlags { flags }
    override var scrollingDeltaY: CGFloat { delta }
    override var momentumPhase: NSEvent.Phase { [] }
    override var phase: NSEvent.Phase { [] }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var timestamp: TimeInterval { 10 }
}
func heightWheel(_ flags: NSEvent.ModifierFlags, delta: CGFloat = 1, precise: Bool = false) -> NSEvent {
    let event = HeightWheelFixtureEvent()
    event.fixtureWindow = heightWindow; event.flags = flags
    event.delta = delta; event.precise = precise
    event.point = wheelView.convert(CGPoint(x: 100, y: 40), to: nil)
    return event
}
// A native fixture supplies only event/window data; the production handler decides its action.
for flags: NSEvent.ModifierFlags in [.command, .control, .shift] {
    for precise in [false, true] {
        for delta: CGFloat in [-1, 1] {
            let before = wheelPublications
            precondition(wheelView.handle(heightWheel(flags, delta: delta, precise: precise)),
                         "Command, Control and Shift each reach the mixer's height callback")
            precondition(wheelPublications == before + 1)
            precondition(delta > 0 ? wheelFactors.last! > 1 : wheelFactors.last! < 1,
                         "each modifier preserves shrinking and expanding input")
            precondition(wheelSmoothing.last == !precise, "only a physical wheel requests smoothing")
        }
    }
}
let publicationsBeforePlain = wheelPublications
precondition(!wheelView.handle(heightWheel([])) && wheelPublications == publicationsBeforePlain,
             "plain scrolling keeps native vertical movement")
NativeTimelineInputGate.shared.setBlocked(true, for: heightWindow)
for flags: NSEvent.ModifierFlags in [.command, .control, .shift] {
    precondition(!wheelView.handle(heightWheel(flags)) && wheelPublications == publicationsBeforePlain,
                 "modal gate blocks all shared-height shortcuts")
}
NativeTimelineInputGate.shared.setBlocked(false, for: heightWindow)
heightWindow.close()
print("TRACK_HEIGHT_NATIVE_COMMAND_CONTROL_SHIFT_BOTH_DIRECTIONS_PRECISE_DISCRETE_AND_MODAL_GATE_OK")
