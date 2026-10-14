import Foundation
import AVFoundation

setbuf(stdout, nil)

@MainActor func runAnalysisLifecycleTests() throws {
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let source = AVAudioSourceNode { silent, _, frames, buffers in
        silent.pointee = false
        for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
            buffer.mData!.assumingMemoryBound(to: Float.self).update(repeating: 0.125, count: Int(frames))
        }
        return noErr
    }
    engine.attach(source)
    let chain = NativeEffectsChain()
    chain.attach(to: engine, input: source, format: format)
    engine.connect(chain.output, to: engine.mainMixerNode, format: format)
    defer { engine.stop(); chain.detach(from: engine) }
    var settings = NativeFXSettings()
    settings.inserted = ["Delay"]
    settings.delayEnabled = true; settings.delayMix = 0
    var secondSettings = NativeFXSettings()
    secondSettings.delayEnabled = true; secondSettings.delayMix = 0
    let second = NativeFXInstance(kind: "Delay", settings: secondSettings)
    settings.instances = [second]; settings.inserted.append(second.effectKey)
    chain.apply(settings)

    // A selected editor may change before SwiftUI disposes the preceding
    // view. Adjacent delays share the same output/input analysis boundary.
    chain.observe(["Delay"])
    chain.observe([second.effectKey])
    chain.observe(["Delay", second.effectKey])
    print("FX_ADJACENT_DELAY_ANALYSIS_SWITCH_AND_SHARED_BOUNDARY_OK rate=\(rate)")

    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    try engine.start()
    var renderIndex = 0
    func render() throws {
        renderIndex += 1
        for _ in 0..<16 {
            let result = try engine.renderOffline(512, to: output)
            precondition(result == .success)
            for channel in 0..<2 {
                precondition(UnsafeBufferPointer(start: output.floatChannelData![channel], count: 512)
                    .allSatisfy { $0.isFinite && abs($0) <= 0.13 })
            }
        }
        precondition(abs(output.floatChannelData![0][511]) > 0.01,
            "analysis changes must leave the running PCM audible; render=\(renderIndex), sample=\(output.floatChannelData![0][511])")
    }
    try render()
    for index in 0..<12 {
        settings.inserted = index.isMultiple(of: 2) ? [second.effectKey, "Delay"] : ["Delay", second.effectKey]
        chain.apply(settings)
        chain.observe(index.isMultiple(of: 2) ? [second.effectKey] : ["Delay", second.effectKey])
        try render()
    }
    settings.inserted = ["Delay"]; settings.instances = nil
    chain.apply(settings); chain.observe(["Delay"]); try render()
    chain.observe([])
    precondition(chain.spectrum("Delay") == nil && chain.spectrum(second.effectKey) == nil)
    chain.observe(["Delay"]); try render(); chain.observe([])
    print("FX_DELAY_ANALYSIS_REORDER_REMOVE_AND_CLOSE_OFFLINE_OK rate=\(rate)")

    // Player scheduling must survive observation changes. Keep graph order
    // fixed here to isolate tap ownership from graph-reordering behavior.
    let playerEngine = AVAudioEngine(), player = AVAudioPlayerNode(), playerChain = NativeEffectsChain()
    try playerEngine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    playerEngine.attach(player)
    playerChain.attach(to: playerEngine, input: player, format: format)
    playerEngine.connect(playerChain.output, to: playerEngine.mainMixerNode, format: format)
    settings.instances = [second]; settings.inserted = ["Delay", second.effectKey]
    playerChain.apply(settings)
    defer { playerEngine.stop(); playerChain.detach(from: playerEngine) }
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
    pcm.frameLength = pcm.frameCapacity
    for channel in 0..<2 { pcm.floatChannelData![channel].update(repeating: 0.125, count: Int(pcm.frameLength)) }
    player.scheduleBuffer(pcm, at: nil, options: .loops, completionHandler: nil)
    try playerEngine.start(); player.play()
    let observations: [Set<String>] = [["Delay"], [second.effectKey], ["Delay", second.effectKey], [], [second.effectKey], ["Delay"], []]
    for observed in observations {
        playerChain.observe(observed)
        for _ in 0..<16 {
            let result = try playerEngine.renderOffline(512, to: output)
            precondition(result == .success)
        }
        precondition(player.isPlaying && abs(output.floatChannelData![0][511] - 0.125) < 0.0001,
            "changing analysis must preserve scheduled audio and its level")
    }
    print("FX_DELAY_ANALYSIS_SWITCH_PRESERVES_PLAYER_AND_PCM_OK rate=\(rate)")
}

try MainActor.assumeIsolated { try runAnalysisLifecycleTests() }
