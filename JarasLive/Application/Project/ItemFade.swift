import Foundation

public extension AudioClip {
    var showsFadeHandles: Bool {
        fadeControlsEnabled == true || (fadeIn ?? 0) > 0 || (fadeOut ?? 0) > 0
    }

    func supportsFades(on track: Track) -> Bool {
        duration > 0 && (isProjectionMedia ||
            (track.kind == .standard && (midi != nil || (audioFile ?? track.audioFile) != nil)))
    }

    mutating func setFadeControlsEnabled(_ enabled: Bool) {
        if enabled {
            guard fadeControlsEnabled != true else { return }
            fadeControlsEnabled = true
            let initial = min(0.05, duration / 4)
            if (fadeIn ?? 0) <= 0 { fadeIn = initial }
            if (fadeOut ?? 0) <= 0 { fadeOut = initial }
        } else {
            fadeControlsEnabled = nil
            fadeIn = nil
            fadeOut = nil
            fadeTimelineStart = nil
            fadeTimelineDuration = nil
        }
    }

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
