import SwiftUI

/// Transient gain changes are observed only by the active item's drawing layer.
/// They never mutate project arrays, waveform storage or structural layout keys.
@MainActor final class ItemGainPreview: ObservableObject {
    struct State: Equatable {
        let id: UUID
        let gain: Double
        func applying(to source: AudioClip) -> AudioClip {
            var clip = source; clip.gain = gain; return clip
        }
    }
    @Published private(set) var state: State?
    func update(id: UUID, gain: Double) {
        let next = State(id: id, gain: gain)
        if state != next { state = next }
    }
    func clear() { if state != nil { state = nil } }
}
