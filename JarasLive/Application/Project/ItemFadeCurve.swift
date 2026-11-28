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

public struct WaveLFOEnvelope: Codable, Equatable, Hashable, Sendable {
    public static let name = "Wave LFO"
    public var attack = 0.05, hold = 0.0, decay = 0.20, sustain = 0.75, release = 0.25
    public init() {}

    private enum CodingKeys: String, CodingKey { case attack, hold, decay, sustain, release }
    public init(from decoder: Decoder) throws {
        let data = try decoder.container(keyedBy: CodingKeys.self)
        attack = try data.decode(Double.self, forKey: .attack)
        hold = try data.decodeIfPresent(Double.self, forKey: .hold) ?? 0
        decay = try data.decode(Double.self, forKey: .decay)
        sustain = try data.decode(Double.self, forKey: .sustain)
        release = try data.decode(Double.self, forKey: .release)
    }

    public func fitted(to duration: Double) -> Self {
        let total = attack + hold + decay + release
        guard total > duration, total > 0 else { return self }
        let scale = max(0, duration) / total
        var copy = self
        copy.attack *= scale
        copy.hold *= scale
        copy.decay *= scale
        copy.release *= scale
        return copy
    }

    public func vertices(duration: Double) -> [(time: Double, gain: Double)] {
        let e = fitted(to: duration)
        return [(0, 0), (e.attack, 1), (e.attack + e.hold, 1),
                (e.attack + e.hold + e.decay, e.sustain), (duration - e.release, e.sustain), (duration, 0)]
    }
}
