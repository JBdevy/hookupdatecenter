import AppKit

// One second of the same native travel, delivered at different frequencies or
// coalesced while an older Mac is busy, must move the same number of points.
for precise in [false, true] {
    for viewport: CGFloat in [240, 480, 600, 900, 1400] {
        for rate in [15.0, 20, 30, 60, 120, 240] {
            for inputSpeed: CGFloat in [300, 1200, 3600] {
                var velocity = NativeMixerScrollVelocity()
                _ = velocity.limit(0, timestamp: 100, viewport: viewport, precise: precise)
                var travelled: CGFloat = 0
                for index in 1...Int(rate) {
                    travelled += velocity.limit(inputSpeed / rate, timestamp: 100 + Double(index) / rate,
                                                viewport: viewport, precise: precise)
                }
                let expected = min(inputSpeed, NativeMixerScrollVelocity.maximum(viewport: viewport))
                precondition(abs(travelled - expected) < 0.001,
                             "Window size and input delivery rate must not change gesture travel")
                precondition(velocity.limit(-1, timestamp: 101.02, viewport: viewport, precise: precise) == -1,
                             "A reversal must respond without replaying any discarded motion")
                precondition(velocity.limit(1000, timestamp: 101.02, viewport: viewport, precise: precise) == 0,
                             "Duplicate event timestamps cannot spend the time budget twice")
                let freshBudget = NativeMixerScrollVelocity.maximum(viewport: viewport) / (precise ? 60 : 30)
                precondition(abs(velocity.limit(1000, timestamp: 102, viewport: viewport, precise: precise) - freshBudget) < 0.001,
                             "An idle gap must not become a large catch-up jump")
            }
        }
    }
}
print("MIXER_SCROLL_DISTANCE_INDEPENDENT_OF_VIEWPORT_AND_EVENT_RATE_OK")
