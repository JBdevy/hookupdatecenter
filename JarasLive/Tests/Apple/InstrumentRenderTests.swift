import AVFoundation
import Foundation
let path = CommandLine.arguments[1]
let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
let engine = AVAudioEngine()
let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
let instrument = try JarasSoundFont(url: URL(fileURLWithPath: path), sampleRate: rate)
engine.attach(instrument.node)
engine.connect(instrument.node, to: engine.mainMixerNode, format: format)
let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
try engine.start()
func rms(_ seconds: Double) throws -> Double {
    var squares = 0.0, count = 0
    for _ in 0..<Int(ceil(seconds * rate / 512)) {
        guard try engine.renderOffline(512, to: output) == .success else { continue }
        for channel in 0..<2 { for frame in 0..<Int(output.frameLength) {
            let sample = Double(output.floatChannelData![channel][frame])
            precondition(sample.isFinite)
            squares += sample * sample; count += 1
        } }
    }
    return sqrt(squares / Double(max(1,count)))
}
func note(gain: Double, attack: Double = 0.001) throws -> Double {
    instrument.silence(); _ = try rms(0.03)
    instrument.setGain(gain, pan: 0)
    instrument.setEnvelopeAttack(attack, hold: 0, decay: 0.001, sustain: 1, release: 0.01)
    instrument.sendStatus(0x90, data1: 60, data2: 110)
    return try rms(0.1)
}
let full = try note(gain: 0)
precondition(full > 0.001, "SF2 must produce real audio: \(full)")
let quiet = try note(gain: -12)
precondition(quiet / full > 0.20 && quiet / full < 0.31, "gain must change rendered PCM: \(quiet/full)")
let attack = try note(gain: 0, attack: 2)
precondition(attack < full * 0.2, "attack knob must control SF2 onset: \(attack/full)")
_ = try rms(2)
instrument.sendStatus(0x80, data1: 60, data2: 0)
_ = try rms(0.1)
let released = try rms(0.1)
precondition(released < 0.000001, "release ends the note: \(released)")
_ = try note(gain: 0)
instrument.sendStatus(0xb0, data1: 64, data2: 127)
instrument.silence()
let stopped = try rms(0.1)
precondition(stopped == 0, "Stop silences even sustained MIDI notes: \(stopped)")
instrument.setEnvelopeAttack(0, hold: 0.2, decay: 0.001, sustain: 0, release: 0.01)
instrument.sendStatus(0x90, data1: 60, data2: 110)
let held = try rms(0.1)
precondition(held > 0.01, "Hold sustains the attack level even with Sustain at zero")
_ = try rms(0.3)
let holdEnded = try rms(0.1)
precondition(holdEnded < 0.000001, "Hold expires into decay and the selected Sustain level")
print("SF2_HOLD_OK")
print("SF2_GAIN_ENVELOPE_RELEASE_STOP_OK rate=\(rate) full=\(full) gainRatio=\(quiet/full) attackRatio=\(attack/full)")
