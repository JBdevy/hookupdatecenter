import SwiftUI

enum TimelineItemWaveformColors {
    static let invertedBackground = Color(hex: 0x202020)
    static let invertedBackgroundRGB = SIMD4<Float>(32.0 / 255, 32.0 / 255, 32.0 / 255, 1)
    static func usesBlackTitle(trackColor: UInt32, selected: Bool = false, silenced: Bool, inverted: Bool) -> Bool {
        let surface = silenced ? (selected ? UInt32(0xb3b3b3) : 0x8c8c8c) : inverted ? 0x202020 : trackColor
        return TrackNameContrast.foreground(surface, opacity: 1, background: 0,
            emphasized: selected && !silenced && !inverted) == 0
    }
    static func hasWaveform(_ clip: AudioClip, track: Track) -> Bool {
        guard !clip.isProjectionMedia, !clip.isImage else { return false }
        return track.kind == .click || (track.kind == .standard && (clip.midi == nil || clip.frozenMIDI == true))
    }
    static func ink(rgb: SIMD4<Float>, silenced: Bool) -> SIMD4<Float> {
        silenced ? SIMD4(0, 0, 0, 1) : SIMD4(rgb.x, rgb.y, rgb.z, 1)
    }
}
