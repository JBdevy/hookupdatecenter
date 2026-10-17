import SwiftUI

/// Transient gain and fade changes are observed only by the active item's drawing layer.
/// They never mutate project arrays, waveform storage or structural layout keys.
@MainActor final class ItemWaveformPreview: ObservableObject {
    struct State: Equatable {
        let id: UUID
        enum Adjustment: Equatable {
            case gain(Double)
            case fade(fadeIn: Bool, seconds: Double)
            case shape(fadeIn: Bool, sCurve: Bool, value: Double)
        }
        let adjustment: Adjustment
        func applying(to source: AudioClip) -> AudioClip {
            var clip = source
            switch adjustment {
            case .gain(let gain): clip.gain = gain
            case .fade(let fadeIn, let seconds):
                if fadeIn { clip.fadeIn = seconds } else { clip.fadeOut = seconds }
            case .shape(let fadeIn, let sCurve, let value):
                if fadeIn {
                    if sCurve { clip.fadeInSCurve = value } else { clip.fadeInCurve = value }
                } else {
                    if sCurve { clip.fadeOutSCurve = value } else { clip.fadeOutCurve = value }
                }
            }
            return clip
        }
    }
    @Published private(set) var state: State?
    func update(id: UUID, gain: Double) {
        let next = State(id: id, adjustment: .gain(gain))
        if state != next { state = next }
    }
    func updateFade(_ source: AudioClip, fadeIn: Bool, seconds: Double) {
        guard seconds.isFinite else { return }
        let value = min(source.duration, max(0, seconds))
        guard value != (fadeIn ? source.fadeIn : source.fadeOut) ?? 0 else { clear(); return }
        let next = State(id: source.id, adjustment: .fade(fadeIn: fadeIn, seconds: value))
        if state != next { state = next }
    }
    func updateShape(_ source: AudioClip, fadeIn: Bool, sCurve: Bool, value: Double) {
        guard value.isFinite else { return }
        let value = min(1, max(-1, value)), curve = source.fadeCurve(fadeIn)
        guard value != (sCurve ? curve.sCurve : curve.curvature) else { clear(); return }
        let next = State(id: source.id, adjustment: .shape(fadeIn: fadeIn, sCurve: sCurve, value: value))
        if state != next { state = next }
    }
    func clear() { if state != nil { state = nil } }
}
