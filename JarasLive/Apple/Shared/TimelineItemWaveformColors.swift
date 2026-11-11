import SwiftUI

enum TimelineItemWaveformColors {
    static func hasWaveform(_ clip: AudioClip, track: Track) -> Bool {
        guard !clip.isProjectionMedia, !clip.isImage else { return false }
        return track.kind == .click || (track.kind == .standard && (clip.midi == nil || clip.frozenMIDI == true))
    }
    static func ink(rgb: SIMD4<Float>, silenced: Bool) -> SIMD4<Float> {
        SIMD4(0, 0, 0, 1)
    }
}
