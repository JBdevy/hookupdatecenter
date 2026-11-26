import Foundation

public struct ItemFadeCurve: Equatable, Sendable {
    public var curvature: Double
    public var sCurve: Double
    public init(curvature: Double = 0, sCurve: Double = 1) {
        self.curvature = min(1, max(-1, curvature))
        self.sCurve = min(1, max(-1, sCurve))
    }
    public func value(at position: Double) -> Double {
        let t = min(1, max(0, position))
        let shaped = t + sCurve * (t * t * (3 - 2 * t) - t)
        let bias = exp2(4 * curvature)
        return shaped / (bias + (1 - bias) * shaped)
    }
    /// Position on the curve at a specified level, used by the two draggable grips.
    public func position(at level: Double) -> Double {
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let middle = (low + high) / 2
            if value(at: middle) < level { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }
}
