import SwiftUI

/// Transient gain, pan and fade changes are observed only by the affected items' drawing layers.
/// They never mutate project arrays, waveform storage or structural layout keys.
@MainActor final class ItemWaveformPreview: ObservableObject {
    struct State: Equatable {
        let id: UUID
        var targets: Set<UUID> = []
        var ids: Set<UUID> { targets.isEmpty ? [id] : targets }
        enum Adjustment: Equatable {
            case gain(Double)
            case pan(Double)
            case fade(fadeIn: Bool, seconds: Double)
            case shape(fadeIn: Bool, sCurve: Bool, value: Double)
        }
        let adjustment: Adjustment
        func applying(to source: AudioClip) -> AudioClip {
            var clip = source
            switch adjustment {
            case .gain(let gain): clip.gain = gain
            case .pan(let pan): clip.pan = pan
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
    private var awaitingPresentation = false
    /// Retain the last drag frame until the base layer has rendered that value.
    func finish(committed clip: AudioClip?) {
        guard let state, let clip, state.applying(to: clip) == clip else { clear(); return }
        awaitingPresentation = true
    }
    func didPresent(_ song: Song) {
        guard awaitingPresentation, let expected = state,
              case let clips = song.tracks.flatMap(\.clips).filter({ expected.ids.contains($0.id) }),
              clips.count == expected.ids.count,
              clips.allSatisfy({ expected.applying(to: $0) == $0 }) else { return }
        // Presentation can happen inside an NSViewRepresentable update.
        // Publish after that update, checking for a newer drag before clearing.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.awaitingPresentation, self.state == expected else { return }
            self.clear()
        }
    }
    func update(id: UUID, gain: Double, targets: Set<UUID> = []) {
        awaitingPresentation = false
        let next = State(id: id, targets: targets, adjustment: .gain(gain))
        if state != next { state = next }
    }
    func updatePan(id: UUID, pan: Double, targets: Set<UUID> = []) {
        awaitingPresentation = false
        let next = State(id: id, targets: targets, adjustment: .pan(pan))
        if state != next { state = next }
    }
    func updateFade(_ source: AudioClip, fadeIn: Bool, seconds: Double) {
        awaitingPresentation = false
        guard seconds.isFinite else { return }
        let value = min(source.duration, max(0, seconds))
        guard value != (fadeIn ? source.fadeIn : source.fadeOut) ?? 0 else { clear(); return }
        let next = State(id: source.id, adjustment: .fade(fadeIn: fadeIn, seconds: value))
        if state != next { state = next }
    }
    func updateShape(_ source: AudioClip, fadeIn: Bool, sCurve: Bool, value: Double) {
        awaitingPresentation = false
        guard value.isFinite else { return }
        let value = min(1, max(-1, value)), curve = source.fadeCurve(fadeIn)
        guard value != (sCurve ? curve.sCurve : curve.curvature) else { clear(); return }
        let next = State(id: source.id, adjustment: .shape(fadeIn: fadeIn, sCurve: sCurve, value: value))
        if state != next { state = next }
    }
    func clear() { awaitingPresentation = false; if state != nil { state = nil } }
}
