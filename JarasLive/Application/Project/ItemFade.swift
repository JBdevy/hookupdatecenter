import Foundation

public extension AudioClip {
    func fadeCurve(_ fadeIn: Bool) -> ItemFadeCurve {
        ItemFadeCurve(curvature: (fadeIn ? fadeInCurve : fadeOutCurve) ?? 0,
                      sCurve: (fadeIn ? fadeInSCurve : fadeOutSCurve) ?? 1)
    }
    func fadeGain(at position: Double) -> Double {
        let duration = fadeTimelineDuration ?? self.duration
        let elapsed = position - (fadeTimelineStart ?? startTime)
        let start = min(duration, fadeIn ?? 0), end = min(duration, fadeOut ?? 0)
        return (start > 0 ? fadeCurve(true).value(at: elapsed / start) : 1)
             * (end > 0 ? fadeCurve(false).value(at: (duration - elapsed) / end) : 1)
    }
}
