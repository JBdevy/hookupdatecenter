import Foundation
import AVFoundation
import Darwin
let legacy = CommandLine.arguments.contains("--legacy")
let activeCount = CommandLine.arguments.contains("--all-active") ? 48 : 24
let engine = AVAudioEngine()
let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
source.frameLength = 4096
for c in 0..<2 { for i in 0..<4096 { source.floatChannelData![c][i] = 0.002 } }
var players: [AVAudioPlayerNode] = [], chains: [NativeEffectsChain] = [], gains: [AVAudioUnit] = []
for index in 0..<48 {
    let player = AVAudioPlayerNode(), chain = NativeEffectsChain(reorderable: false)
    let gain: AVAudioUnit
    if legacy {
        let node = AVAudioUnitEQ(numberOfBands: 0)
        node.globalGain = index < activeCount ? -6 : -96
        gain = node
    } else {
        let node = JarasVoiceGain.makeNode()
        JarasVoiceGain.setDecibels(node, decibels: -6)
        JarasVoiceGain.setRenderEnabled(node, enabled: index < activeCount)
        gain = node
    }
    engine.attach(player); engine.attach(gain)
    chain.attach(to: engine, input: player, format: format)
    engine.connect(chain.output, to: gain, format: format)
    engine.connect(gain, to: engine.mainMixerNode, format: format)
    if index < activeCount { player.scheduleBuffer(source, at: nil, options: .loops) }
    players.append(player); chains.append(chain); gains.append(gain)
}
try engine.start(); players.prefix(activeCount).forEach { $0.play() }
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
func render(_ count: Int) throws {
    for _ in 0..<count { let status = try engine.renderOffline(512, to: buffer); precondition(status == .success) }
    let expected = Float(activeCount) * 0.002 * pow(10, -6 / 20.0)
    for c in 0..<2 { for i in 0..<512 { precondition(abs(buffer.floatChannelData![c][i] - expected) < 0.00001) } }
}
func cpu() -> Double {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}
try render(100)
var samples: [Double] = []
for _ in 0..<5 {
    let start = cpu(); try render(2000); samples.append(cpu()-start)
}
print(String(data: try JSONSerialization.data(withJSONObject: ["legacy": legacy, "active": activeCount, "voices": 48,
    "audio_seconds_per_sample": 2000.0*512/48000, "cpu_seconds": samples]), encoding: .utf8)!)
engine.stop()
