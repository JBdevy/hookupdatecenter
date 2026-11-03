import SwiftUI

enum TimelineItemWaveformColors {
    static func hasWaveform(_ clip: AudioClip, track: Track) -> Bool {
        guard !clip.isProjectionMedia, !clip.isImage else { return false }
        return track.kind == .click || (track.kind == .standard && (clip.midi == nil || clip.frozenMIDI == true))
    }
    static func ink(rgb: SIMD4<Float>, silenced: Bool) -> SIMD4<Float> {
        let dim: Float = silenced ? 0.55 : 1
        return SIMD4(rgb.x * dim, rgb.y * dim, rgb.z * dim, 1)
    }
}
