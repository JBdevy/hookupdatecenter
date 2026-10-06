import Foundation
import AVFoundation
import Darwin
let engine = AVAudioEngine()
let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
source.frameLength = 4096
for c in 0..<2 { for i in 0..<4096 { source.floatChannelData![c][i] = 0.002 } }
var players: [AVAudioPlayerNode] = [], chains: [NativeEffectsChain] = []
for _ in 0..<48 {
    let player = AVAudioPlayerNode(), chain = NativeEffectsChain(reorderable: false)
    engine.attach(player); chain.attach(to: engine, input: player, format: format)
    engine.connect(chain.output, to: engine.mainMixerNode, format: format)
    player.scheduleBuffer(source, at: nil, options: .loops)
    players.append(player); chains.append(chain)
}
try engine.start(); players.forEach { $0.play() }
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
func render(_ count: Int) throws {
    for _ in 0..<count { let status = try engine.renderOffline(512, to: buffer); precondition(status == .success) }
    for c in 0..<2 { for i in 0..<512 { precondition(abs(buffer.floatChannelData![c][i] - 0.096) < 0.0001) } }
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
print(String(data: try JSONSerialization.data(withJSONObject: ["separate": ProcessInfo.processInfo.environment["CATLIVE_BENCHMARK_SEPARATE"] == "1", "voices": 48, "audio_seconds_per_sample": 2000.0*512/48000, "cpu_seconds": samples]), encoding: .utf8)!)
engine.stop()
