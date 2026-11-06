import Foundation
import AVFoundation

// Driver-free regression for the production AUs. Run on Intel and Apple
// Silicon; the test-audio.sh target remains macOS 12. No speed-based assertions.
private enum DynamicsCase: Equatable { case normal, invalid, outOfRange, boundedReference }

private func configure(_ node: AVAudioUnitEffect, kind: String, stage: Int, mode: DynamicsCase) {
    if stage == 1 {
        guard mode == .invalid else { return }
        switch kind {
        case "Compressor": JarasDynamics.configureCompressor(node, enabled: false, threshold: -20, ratio: 4, attack: 0.005, release: 0.1, gain: .nan)
        case "Limiter": JarasDynamics.configureLimiter(node, enabled: false, gain: .infinity, ceiling: -6, release: 0.1)
        default: JarasDynamics.configureReverb(node, enabled: false, space: 0, mix: .nan, decay: 1, lowCut: 80, highCut: 12000)
        }
        return
    }
    let bounded = stage == 2 && (mode == .outOfRange || mode == .boundedReference)
    let oversized = bounded && mode == .outOfRange
    switch kind {
    case "Compressor":
        JarasDynamics.configureCompressor(node, enabled: true,
            threshold: bounded ? (oversized ? 100 : 0) : -20,
            ratio: bounded ? (oversized ? 100 : 20) : 4,
            attack: bounded ? (oversized ? -1 : 0.0001) : 0.005,
            release: bounded ? (oversized ? 100 : 3) : 0.1,
            gain: bounded ? (oversized ? 100 : 24) : 3)
    case "Limiter":
        JarasDynamics.configureLimiter(node, enabled: true,
            gain: bounded ? (oversized ? 100 : 24) : 6,
            ceiling: bounded ? (oversized ? -100 : -24) : -6,
            release: bounded ? (oversized ? 100 : 3) : 0.1)
    default:
        JarasDynamics.configureReverb(node, enabled: true,
            space: bounded ? (oversized ? 99 : 2) : (stage == 2 ? 0 : 1),
            mix: bounded ? (oversized ? 150 : 100) : 35,
            decay: bounded ? (oversized ? -1 : 0.1) : (stage == 2 ? 0.4 : 2),
            lowCut: bounded ? (oversized ? -1 : 20) : (stage == 2 ? 400 : 80),
            highCut: bounded ? (oversized ? 100000 : 20000) : (stage == 2 ? 6000 : 12000))
    }
}

private func renderDynamics(kind: String, rate: Double, block: AVAudioFrameCount, mode: DynamicsCase) throws -> [Float] {
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    var sourceFrame = 0
    let source = AVAudioSourceNode(format: format) { _, _, count, list in
        for (channel, buffer) in UnsafeMutableAudioBufferListPointer(list).enumerated() {
            let values = buffer.mData!.assumingMemoryBound(to: Float.self)
            for frame in 0..<Int(count) {
                let at = sourceFrame + frame
                // Clean reference substitutes zeros at exactly the corrupt
                // source samples; valid stereo PCM must remain unchanged.
                if at == 1024 || at == 1025 {
                    values[frame] = mode == .invalid ? (channel == 0 ? .nan : .infinity) : 0
                } else {
                    values[frame] = Float(0.25 * sin(2 * .pi * 440 * Double(at) / rate)) * (channel == 0 ? 1 : -0.5)
                }
            }
        }
        sourceFrame += Int(count)
        return noErr
    }
    let effect: AVAudioUnitEffect
    switch kind {
    case "Compressor": effect = JarasDynamics.makeCompressor()
    case "Limiter": effect = JarasDynamics.makeLimiter()
    default: effect = JarasDynamics.makeReverb()
    }
    engine.attach(source); engine.attach(effect)
    engine.connect(source, to: effect, format: format)
    engine.connect(effect, to: engine.mainMixerNode, format: format)
    configure(effect, kind: kind, stage: 0, mode: mode)
    try engine.start()
    defer { engine.stop() }
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    var output: [Float] = []
    output.reserveCapacity(20480 * 2)
    for at in stride(from: 0, to: 20480, by: Int(block)) {
        if at == 4096 { configure(effect, kind: kind, stage: 1, mode: mode) }
        if at == 8192 { configure(effect, kind: kind, stage: 2, mode: mode) }
        if at == 12288 { effect.auAudioUnit.reset() }
        let status = try engine.renderOffline(block, to: pcm)
        precondition(status == .success, "Dynamics offline render failed")
        for frame in 0..<Int(pcm.frameLength) {
            output.append(pcm.floatChannelData![0][frame])
            output.append(pcm.floatChannelData![1][frame])
        }
    }
    precondition(output.allSatisfy(\.isFinite), "\(kind): non-finite output at \(rate) Hz")
    precondition(output.suffix(2048).contains { abs($0) > 0.0001 }, "\(kind): DSP remained poisoned or silent")
    return output
}

private func equalPCM(_ a: [Float], _ b: [Float], label: String) {
    precondition(a.count == b.count, "\(label): changed render length")
    precondition(zip(a, b).allSatisfy { abs($0.0 - $0.1) < 0.000002 }, "\(label): valid PCM or state changed")
}

for rate in [44100.0, 48000, 96000] {
    for kind in ["Compressor", "Limiter", "Reverb"] {
        let normal = try renderDynamics(kind: kind, rate: rate, block: 512, mode: .normal)
        equalPCM(normal, try renderDynamics(kind: kind, rate: rate, block: 512, mode: .invalid),
                 label: "\(kind) invalid PCM/configuration recovery")
        equalPCM(normal, try renderDynamics(kind: kind, rate: rate, block: 64, mode: .normal),
                 label: "\(kind) coefficient cache, changes and reset across callback sizes")
        equalPCM(try renderDynamics(kind: kind, rate: rate, block: 512, mode: .outOfRange),
                 try renderDynamics(kind: kind, rate: rate, block: 512, mode: .boundedReference),
                 label: "\(kind) caller parameter bounds")
    }
}
print("DYNAMICS_FINITE_PCM_PARAMETERS_BLOCK_PARTITIONS_AND_RESET_OK")
