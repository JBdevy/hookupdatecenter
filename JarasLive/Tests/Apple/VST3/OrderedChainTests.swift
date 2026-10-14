import Foundation
import AVFoundation
import Darwin
try MainActor.assumeIsolated {
    let path = CommandLine.arguments[1]
    let fixture = dlopen(Bundle(path: path)!.executablePath!, RTLD_NOW | RTLD_LOCAL)!
    defer { dlclose(fixture) }
    func diagnostic(_ name: String) -> Int32 {
        let read = unsafeBitCast(dlsym(fixture, name)!, to: (@convention(c) () -> Int32).self)
        return read()
    }
    var error: NSError?
    let catalog = JarasVST3.scan(path, error: &error)
    precondition(error == nil && catalog.count == 1)
    for rate in [44100.0, 48000.0] {
        let engine = AVAudioEngine(), format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        let source = AVAudioSourceNode(format: format) { silence, _, count, list in
            silence.pointee = false
            for buffer in UnsafeMutableAudioBufferListPointer(list) { buffer.mData!.assumingMemoryBound(to: Float.self).update(repeating: 0.5, count: Int(count)) }
            return noErr
        }
        let chain = NativeEffectsChain(); engine.attach(source)
        chain.attach(to: engine, input: source, format: format)
        engine.connect(chain.output, to: engine.mainMixerNode, format: format)
        let plugin = ExternalPlugin(classID: catalog[0]["classID"] as! String, name: "Gain fixture", path: path)
        var settings = NativeFXSettings(); settings.externalPlugins = [plugin]
        settings.inserted = [plugin.effectKey, "Compressor"]
        settings.compressorEnabled = true; settings.threshold = -20; settings.ratio = 10; settings.attack = 0.0001
        chain.apply(settings)
        precondition(chain.externalError == nil)
        let node = chain.externalNode(plugin.id)!
        precondition(diagnostic("catliveLastSetupMode") == 2,
                     "export must set kOffline during setupProcessing, before engine.prepare/start propagates the AU flag")
        try engine.start()
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        func level() throws -> Float {
            for _ in 0..<100 { let status = try engine.renderOffline(512, to: output); precondition(status == .success) }
            return output.floatChannelData![0][128]
        }
        let before = try level()
        precondition(diagnostic("catliveLastProcessMode") == 2 && diagnostic("catliveProcessModeMismatches") == 0,
                     "offline process blocks must match the mode used by setupProcessing")
        settings.inserted = ["Compressor", plugin.effectKey]
        chain.apply(settings)
        let after = try level()
        precondition(before > after * 1.5 && after > 0.001, "changing the visual chain must change the real PCM processing order")
        precondition(chain.externalNode(plugin.id) === node, "reordering preserves the VST3 instance and state")
        settings.externalPlugins?[0].bypassed = true; chain.apply(settings)
        let bypass = try level()
        precondition(bypass > after * 1.8, "the sidebar checkbox controls real VST3 bypass")
        settings.inserted = ["Compressor"]; settings.externalPlugins = nil; chain.apply(settings)
        precondition(chain.externalNode(plugin.id) == nil)
        let remaining = try level()
        precondition(abs(remaining - bypass) < 0.0001, "removal keeps the remaining audio chain active")
        settings.inserted = ["Delay", "Compressor"]
        settings.delayEnabled = true; settings.delayMix = 100; settings.delayTime = 0.01; settings.feedback = 0
        chain.apply(settings); chain.observe(["Delay", "Compressor"])
        _ = try level()
        let delayPeaks = chain.effectPeaks("Delay")
        precondition(delayPeaks.count == 4 && delayPeaks.allSatisfy { $0 > 0.45 }, "Delay meters measure its own input and output before the compressor")
        precondition(chain.spectrum("Delay") != nil)
        settings.inserted = ["Compressor", "Delay"]; chain.apply(settings)
        _ = try level()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        _ = chain.effectPeaks("Delay") // Consume the previous delay tail during the handoff.
        _ = try level()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        let movedPeaks = chain.effectPeaks("Delay")
        precondition(movedPeaks.allSatisfy { $0 > 0 && $0 < 0.2 }, "Delay analysis follows its new actual position after the compressor: \(movedPeaks)")
        chain.observe([])
        engine.stop()
        print("ORDERED_NATIVE_AND_VST3_CHAIN_PCM_IDENTITY_BYPASS_REMOVAL_OK rate=\(rate) before=\(before) after=\(after)")
    }

    // No hardware playback is needed to verify live setup or a graph-mode
    // transition. Reusing a plugin ID must not retain the previous DSP mode.
    let engine = AVAudioEngine(), format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let source = AVAudioMixerNode(), chain = NativeEffectsChain()
    engine.attach(source); chain.attach(to: engine, input: source, format: format)
    let plugin = ExternalPlugin(classID: catalog[0]["classID"] as! String, name: "Gain fixture", path: path)
    let node = try chain.prepareExternal(plugin)
    precondition(diagnostic("catliveLastSetupMode") == 0, "live graph retains kRealtime setup")
    let specs = try JSONSerialization.jsonObject(with: JSONEncoder().encode([plugin])) as! [[String: Any]]
    var setups = diagnostic("catliveProcessingSetups")
    try JarasVST3.configure(node, plugins: specs)
    precondition(diagnostic("catliveProcessingSetups") == setups, "unchanged mode reuses the processor")
    for (offline, expected) in [(true, Int32(2)), (false, Int32(0))] {
        node.auAudioUnit.isRenderingOffline = offline
        try JarasVST3.configure(node, plugins: specs)
        setups += 1
        precondition(diagnostic("catliveLastSetupMode") == expected && diagnostic("catliveProcessingSetups") == setups,
                     "realtime/offline transition requires fresh setupProcessing")
    }
    chain.detach(from: engine)
    print("VST3_OFFLINE_SETUP_BEFORE_ENGINE_PREPARE_PROCESS_MODE_MATCH_AND_LIVE_MODE_TRANSITIONS_OK")
}
