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
precondition(values.count == 1 && abs(values[0] - expected) < 0.00001,
             "The first event must reach the screen immediately")
for _ in 0..<120 { delta(exp(0.002)) }
for _ in 0..<75 { delta(exp(-0.002)) }
precondition(values.count == 1, "A burst must not queue hundreds of expensive layout passes")
RunLoop.main.run(until: Date().addingTimeInterval(0.04))
precondition(values.count == 2 && abs(values.last! - expected) < 0.00001,
             "One frame must consume every delta, including immediate direction reversal")
let afterFrame = values.count
RunLoop.main.run(until: Date().addingTimeInterval(0.11))
precondition(values.count == afterFrame, "No interpolation or duplicate geometry after input ends")

motion.change(factor: exp(0.02), current: 160) { values.append($0) }
precondition(abs(values.last! - input(160, exp(0.02))) < 0.00001,
             "A new gesture must use the current height, not the previous gesture")
motion.change(factor: exp(0.10), current: 160) { values.append($0) }
let beforeCancel = values.count
motion.cancel()
RunLoop.main.run(until: Date().addingTimeInterval(0.04))
precondition(values.count == beforeCancel, "Closing or blocking the grid cancels pending layout")
print("TRACK_HEIGHT_FRAME_BATCHING_OK first response, 196 deltas, exact reversal, idle, cancel")
