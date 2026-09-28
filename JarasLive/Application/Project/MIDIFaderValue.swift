import Foundation

/// MIDI CC spans the same -infinity / -60 ... +12 dB travel as the volume fader.
public enum MIDIFaderValue {
    public static func gain(_ value: UInt8) -> Double {
        guard value > 0 else { return 0 }
        let decibels = -60 + Double(min(127, value)) / 127 * 72
        return pow(10, decibels / 20)
    }
}
