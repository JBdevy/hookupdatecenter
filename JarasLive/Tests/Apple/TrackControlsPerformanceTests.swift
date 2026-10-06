import AVFoundation
import Foundation
import Darwin

let separate = CommandLine.arguments.contains("--separate")
let engine = AVAudioEngine()
let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
source.frameLength = 4096
for c in 0..<2 { for i in 0..<4096 { source.floatChannelData![c][i] = c == 0 ? 0.002 : 0.003 } }
var players: [AVAudioPlayerNode] = [], retained: [AVAudioNode] = []
let voices = 48
for _ in 0..<voices {
    let player = AVAudioPlayerNode(), controls = JarasEqualizer.makeNode()
    engine.attach(player); engine.attach(controls); retained.append(controls)
    engine.connect(player, to: controls, format: format)
    if separate {
        let gain = AVAudioMixerNode(), meter = AVAudioMixerNode()
        engine.attach(gain); engine.attach(meter); retained += [gain, meter]
        engine.connect(controls, to: gain, format: format)
        engine.connect(gain, to: meter, format: format)
        engine.connect(meter, to: engine.mainMixerNode, format: format)
        gain.outputVolume = 0.7; gain.pan = 0.2
    } else {
        JarasEqualizer.setInputGain(controls, gain: 0.7)
        JarasEqualizer.setInputPan(controls, pan: 0.2)
        engine.connect(controls, to: engine.mainMixerNode, format: format)
    }
    player.scheduleBuffer(source, at: nil, options: .loops)
    players.append(player)
}
try engine.start(); players.forEach { $0.play() }
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
func render(_ count: Int) throws {
    for _ in 0..<count { precondition(try! engine.renderOffline(512, to: buffer) == .success) }
    let expected: [Float] = [0.002 * 0.7 * 0.8 * Float(voices), 0.003 * 0.7 * Float(voices)]
    for c in 0..<2 { for i in 0..<512 {
        precondition(abs(buffer.floatChannelData![c][i] - expected[c]) < 0.00001,
                     "track controls must preserve the same stereo PCM in both graphs")
    } }
}
func cpu() -> Double {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}
try render(100)
var samples: [Double] = []
for _ in 0..<5 { let start = cpu(); try render(2000); samples.append(cpu() - start) }
print(String(data: try JSONSerialization.data(withJSONObject: ["separate": separate,
    "tracks": voices, "audio_seconds_per_sample": 2000.0 * 512 / 48000, "cpu_seconds": samples]), encoding: .utf8)!)
engine.stop()
