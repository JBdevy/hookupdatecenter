import Foundation
import AVFoundation
import Darwin

final class CapturePCMResult: @unchecked Sendable {
    var blocks = 0
    var maximumError = Float(0)
    var error: Error?
}
try MainActor.assumeIsolated {
    let path = CommandLine.arguments[1]
    let library = dlopen(path + "/Contents/MacOS/GainFixture", RTLD_NOW)!
    defer { dlclose(library) }
    let reads = unsafeBitCast(dlsym(library, "catliveStateReads"), to: (@convention(c) () -> UInt32).self)
    let writes = unsafeBitCast(dlsym(library, "catliveStateWrites"), to: (@convention(c) () -> UInt32).self)
    let delay = unsafeBitCast(dlsym(library, "catliveStateDelay"), to: (@convention(c) (UInt32) -> Void).self)
    let engine = AVAudioEngine(), format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 256)
    let source = AVAudioSourceNode(format: format) { silent, _, frames, list in
        silent.pointee = false
        for channel in UnsafeMutableAudioBufferListPointer(list) {
            channel.mData!.assumingMemoryBound(to: Float.self).update(repeating: 0.2, count: Int(frames))
        }
        return noErr
    }
    let chain = NativeEffectsChain(); engine.attach(source)
    chain.attach(to: engine, input: source, format: format)
    engine.connect(chain.output, to: engine.mainMixerNode, format: format)
    var plugin = ExternalPlugin(classID: "1234123456785678ABCDEF0012345678", name: "Gain", path: path)
    var settings = NativeFXSettings(); settings.inserted = [plugin.effectKey, "EQ"]; settings.externalPlugins = [plugin]
    chain.apply(settings)
    let node = chain.externalNode(plugin.id)!
    JarasVST3.setParameter(node, identifier: plugin.id, parameter: 0, value: 0.37)
    engine.prepare(); try engine.start()
    defer { engine.stop() }
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
    for _ in 0..<8 { let status = try engine.renderOffline(256, to: buffer); precondition(status == .success) }
    let originalNodes = engine.attachedNodes, originalStateWrites = writes()
    let pcm = CapturePCMResult(), started = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        do {
            for _ in 0..<700 {
                let status = try engine.renderOffline(256, to: buffer)
                precondition(status == .success)
                for channel in 0..<2 {
                    for frame in 0..<Int(buffer.frameLength) {
                        pcm.maximumError = max(pcm.maximumError, abs(buffer.floatChannelData![channel][frame] - 0.074))
                    }
                }
                pcm.blocks += 1
                if pcm.blocks == 1 { started.signal() }
                usleep(1_000)
            }
        } catch { pcm.error = error; started.signal() }
        finished.signal()
    }
    started.wait()
    delay(200_000)
    let start = ProcessInfo.processInfo.systemUptime
    let state = JarasVST3.state(node, identifier: plugin.id)!
    let captureDuration = ProcessInfo.processInfo.systemUptime - start
    delay(0)
    plugin.componentState = state["componentState"] as? String
    plugin.controllerState = state["controllerState"] as? String
    settings.externalPlugins = [plugin]
    chain.rememberCapturedPluginState(plugin, source: node)
    finished.wait()
    precondition(pcm.error == nil && pcm.blocks == 700 && pcm.maximumError < 0.000001,
                 "PCM must keep rendering unchanged while plugin state capture stalls the control thread")
    precondition(captureDuration > 0.35 && writes() == originalStateWrites,
                 "The deliberately slow capture must not restore or reset the running preset")
    let savedReadCount = reads()
    for index in 0..<32 {
        settings.bands[0].gain = Double(index % 2)
        chain.apply(settings)
        let status = try engine.renderOffline(256, to: buffer); precondition(status == .success)
    }
    precondition(reads() == savedReadCount && writes() == originalStateWrites,
                 "Later native FX changes must not read or reapply the captured VST3 preset")
    precondition(engine.attachedNodes == originalNodes && chain.externalNode(plugin.id) === node)
    print("SAVE_CAPTURE_CONTINUES_PCM_NO_RESTORE_NO_REWIRE blocks=\(pcm.blocks) captureSeconds=\(captureDuration) error=\(pcm.maximumError)")
}
