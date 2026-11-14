import AVFoundation
import Foundation
import Darwin

setbuf(stdout, nil)
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-prepared-graph-" + UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
let url = directory.appendingPathComponent("source.wav")
let pcm = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 44100 * 8)!
pcm.frameLength = pcm.frameCapacity
for c in 0..<2 { pcm.floatChannelData![c].initialize(repeating: c == 0 ? 0.001 : -0.001, count: Int(pcm.frameLength)) }
try AVAudioFile(forWriting: url, settings: sourceFormat.settings).write(from: pcm)
let engine = AVAudioEngine()
try engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: 512)
var sources: [JarasPreparedClip] = [], chains: [NativeEffectsChain] = []
var gates: [AVAudioUnitEffect] = []
let count = 200
for _ in 0..<count {
    let source = JarasPreparedClip(format: sourceFormat), converter = AVAudioMixerNode(), gate = JarasVoiceGain.makeNode()
    let chain = NativeEffectsChain(reorderable: false, preparesInactiveEffects: false)
    engine.attach(source.node); engine.attach(converter); engine.attach(gate)
    engine.connect(source.node, to: converter, format: sourceFormat)
    chain.attach(to: engine, input: converter, format: format, destinations: [AVAudioConnectionPoint(node: gate, bus: 0)])
    engine.connect(gate, to: engine.mainMixerNode, format: format)
    try source.prepare(url, sourceFrame: 0, endFrame: Double(pcm.frameLength), rate: 1, pitch: 0, loopStart: 0, loopEnd: 0)
    sources.append(source); chains.append(chain); gates.append(gate)
}
try engine.start(); sources.forEach { $0.start(atHostTime: 0, ramp: false) }
let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
var elapsed: [Double] = []
for block in 0..<180 {
    var status: OSStatus = 0
    output.frameLength = 512
    let start = ProcessInfo.processInfo.systemUptime
    precondition(engine.manualRenderingBlock(512, output.mutableAudioBufferList, &status) == .success && status == 0)
    let duration = (ProcessInfo.processInfo.systemUptime - start) * 1000
    if block >= 16 {
        elapsed.append(duration)
        precondition(abs(output.floatChannelData![0][511] - 0.2) < 0.00002 &&
                     abs(output.floatChannelData![1][511] + 0.2) < 0.00002, "Every independent item must contribute to the output")
    }
}
let sorted = elapsed.sorted()
print("PREPARED_ITEM_GRAPH voices=\(count) legacy=\(CommandLine.arguments.contains("--legacy")) nodes=\(engine.attachedNodes.count) meanMs=\(elapsed.reduce(0,+)/Double(elapsed.count)) p95Ms=\(sorted[Int(Double(sorted.count)*0.95)]) maxMs=\(sorted.last!) underruns=\(sources.map(\.underruns).reduce(0,+))")
// Inserting/removing processors on a running prepared source must preserve
// every source cursor, including untouched tracks and the edited item itself.
for effect in ["EQ", "Compressor", "Delay", "Reverb"] {
    var neutral = NativeFXSettings()
    for index in neutral.bands.indices {
        neutral.bands[index].type = "bell"; neutral.bands[index].gain = 0
    }
    neutral.delayMix = 0; neutral.reverbMix = 0
    var settings = neutral
    settings.appendNative(effect)
    // Inserting an effect intentionally restores that effect's defaults.
    // Set the neutral parameters afterwards, so this checks graph continuity
    // rather than the high-pass response or the default wet mix.
    settings.bands = neutral.bands
    settings.delayMix = 0; settings.reverbMix = 0
    for state in [settings, neutral] {
        chains[0].apply(state)
        for block in 0..<4 {
            var status: OSStatus = 0
            precondition(engine.manualRenderingBlock(512, output.mutableAudioBufferList, &status) == .success && status == 0)
            for n in 0..<512 {
                if abs(output.floatChannelData![0][n] - 0.2) >= 0.00002 ||
                   abs(output.floatChannelData![1][n] + 0.2) >= 0.00002 {
                    print("LIVE_FX_FAILURE effect=\(effect) inserted=\(state.inserted) block=\(block) frame=\(n) left=\(output.floatChannelData![0][n]) right=\(output.floatChannelData![1][n]) sources=\(sources.prefix(2).map(\.sourcePosition))")
                    exit(1)
                }
            }
        }
    }
}
print("PREPARED_ITEM_GRAPH_LIVE_FX_CONTINUITY_OK")
sources.forEach { $0.stop() }; engine.stop()
precondition(sources.allSatisfy { $0.underruns == 0 })
