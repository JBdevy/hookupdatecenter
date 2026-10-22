import Foundation
import AVFoundation

final class InputState {
    var frame = 0
    var amplitude: Float = 0
    var impulses = false
}
@MainActor func run() throws {
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    // Sample source uses the opposite rate to exercise playback resampling.
    let sampleRate = rate == 44100 ? 48000.0 : 44100.0
    let sampleFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let sample = AVAudioPCMBuffer(pcmFormat: sampleFormat, frameCapacity: AVAudioFrameCount(sampleRate / 10))!
    sample.frameLength = sample.frameCapacity
    for i in 0..<Int(sample.frameLength) { sample.floatChannelData![0][i] = 0.25; sample.floatChannelData![1][i] = -0.125 }
    let path = directory.appendingPathComponent("hit.wav")
    try AVAudioFile(forWriting: path, settings: sampleFormat.settings).write(from: sample)

    let mp3 = URL(fileURLWithPath: "Tests/Fixtures/trigger-tone.mp3")
    let mp3Node = JarasDynamics.makeTrigger()
    try JarasDynamics.loadTriggerSample(mp3Node, url: mp3)
    precondition((0.19...0.3).contains(JarasDynamics.triggerSampleDuration(mp3Node)), "MP3 sample must decode to playable PCM")
    print("TRIGGER_MP3_DECODE_OK")

    for repeated in [false, true] {
        let engine = AVAudioEngine(), chain = NativeEffectsChain(reorderable: !repeated), input = InputState()
        let source = AVAudioSourceNode(format: format) { _, _, frames, buffers in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            for frame in 0..<Int(frames) {
                let at = input.frame + frame
                let value: Float = input.impulses ? (at == 2048 || at == 12288 ? 0.5 : 0) : input.amplitude * Float(sin(Double(at) * 2 * .pi * 1000 / rate))
                for buffer in list { buffer.mData!.assumingMemoryBound(to: Float.self)[frame] = value }
            }
            input.frame += Int(frames)
            return noErr
        }
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        engine.attach(source); chain.mediaDirectory = directory
        chain.attach(to: engine, input: source, format: format, destinations: [AVAudioConnectionPoint(node: engine.mainMixerNode, bus: 0)])
        var settings = NativeFXSettings(); settings.inserted = ["CatLive Trigger"]; settings.triggerEnabled = true
        var trigger = NativeTriggerSettings(); trigger.samplePath = "hit.wav"; trigger.release = 0; settings.trigger = trigger
        var triggerKey = "CatLive Trigger"
        if repeated {
            let instance = NativeFXInstance(kind: "CatLive Trigger", settings: settings)
            settings = NativeFXSettings(); settings.instances = [instance]; settings.inserted = [instance.effectKey]; triggerKey = instance.effectKey
        }
        chain.apply(settings); chain.observe([triggerKey]); precondition(chain.sampleErrors.isEmpty)
        precondition(abs(chain.triggerTailDuration - 0.1) < 0.0001, "Trigger sample tail must remain audible after its source item ends")
        engine.prepare(); try engine.start(); input.impulses = true
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        var rendered: [Float] = [], right: [Float] = []
        for _ in 0..<32 {
            let status = try engine.renderOffline(512, to: output)
            precondition(status == .success)
            rendered += Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: 512))
            right += Array(UnsafeBufferPointer(start: output.floatChannelData![1], count: 512))
        }
        precondition(abs(rendered[2100] - 0.25) < 0.0001 && abs(right[2100] + 0.125) < 0.0001, "Trigger must play stereo sample on detector edge")
        precondition(abs(rendered[7000]) < 0.0001 && abs(rendered[12300] - 0.25) < 0.0001, "Sample duration and retrigger must survive mismatched sample rate")
        let peaks = chain.effectPeaks(triggerKey); precondition(peaks[0] > 0.49 && peaks[2] > 0.24, "Trigger meters must expose real input/output")
        settings.setEnabled(triggerKey, enabled: false); chain.apply(settings); input.impulses = false; input.amplitude = 0.1
        for _ in 0..<4 { _ = try engine.renderOffline(512, to: output) }
        let peak = (0..<512).map { abs(output.floatChannelData![0][$0]) }.max()!
        precondition(peak > 0.099 && peak < 0.101, "Trigger bypass must restore dry input")
        // Replacing a loaded sample with a missing file cannot keep firing the old sample.
        settings.setEnabled(triggerKey, enabled: true)
        if repeated { settings.instances![0].settings.trigger!.samplePath = "missing.wav" }
        else { settings.trigger!.samplePath = "missing.wav" }
        chain.apply(settings); precondition(chain.sampleErrors[triggerKey] != nil)
        for _ in 0..<4 { _ = try engine.renderOffline(512, to: output) }
        precondition((0..<512).map { abs(output.floatChannelData![0][$0]) }.max()! > 0.099)
        if repeated { settings.instances![0].settings.trigger!.samplePath = "hit.wav" }
        else { settings.trigger!.samplePath = "hit.wav" }
        chain.apply(settings); chain.resetTails(); input.frame = 0; input.impulses = true
        var afterReset: [Float] = []
        for _ in 0..<8 {
            _ = try engine.renderOffline(512, to: output)
            afterReset += Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: 512))
        }
        precondition(chain.sampleErrors.isEmpty && abs(afterReset[2100] - 0.25) < 0.0001, "Sample replacement/reset must preserve parameters and fire cleanly again")
        engine.stop(); chain.detach(from: engine)
        print("TRIGGER_CHAIN_OK repeated=\(repeated) rate=\(rate)")
    }
    for repeated in [false, true] {
        let engine = AVAudioEngine(), chain = NativeEffectsChain(), input = InputState()
        let source = AVAudioSourceNode(format: format) { _, _, frames, buffers in
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                let data = buffer.mData!.assumingMemoryBound(to: Float.self)
                for frame in 0..<Int(frames) { data[frame] = input.amplitude * Float(sin(Double(input.frame + frame) * 2 * .pi * 1000 / rate)) }
            }
            input.frame += Int(frames); return noErr
        }
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        engine.attach(source); chain.attach(to: engine, input: source, format: format, destinations: [AVAudioConnectionPoint(node: engine.mainMixerNode, bus: 0)])
        var settings = NativeFXSettings(); settings.inserted = ["Cat Gate"]; settings.gateEnabled = true
        var gate = NativeGateSettings(); gate.threshold = -20; gate.attack = 0; gate.decay = 0; gate.hold = 0; gate.release = 0.005; settings.gate = gate
        var key = "Cat Gate"
        if repeated { let instance = NativeFXInstance(kind: key, settings: settings); settings = NativeFXSettings(); settings.instances = [instance]; settings.inserted = [instance.effectKey]; key = instance.effectKey }
        chain.apply(settings); engine.prepare(); try engine.start()
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        input.amplitude = 0.01
        for _ in 0..<20 { _ = try engine.renderOffline(512, to: output) }
        precondition((0..<512).map { abs(output.floatChannelData![0][$0]) }.max()! < 0.00001, "Gate must close below threshold")
        input.amplitude = 0.5
        for _ in 0..<20 { _ = try engine.renderOffline(512, to: output) }
        precondition((0..<512).map { abs(output.floatChannelData![0][$0]) }.max()! > 0.49, "Gate must open above threshold")
        settings.setEnabled(key, enabled: false); chain.apply(settings); input.amplitude = 0.01
        for _ in 0..<20 { _ = try engine.renderOffline(512, to: output) }
        precondition((0..<512).map { abs(output.floatChannelData![0][$0]) }.max()! > 0.0099, "Gate bypass must restore quiet input")
        engine.stop(); chain.detach(from: engine)
        print("GATE_CHAIN_OK repeated=\(repeated) rate=\(rate)")
    }
}
try MainActor.assumeIsolated { try run() }
