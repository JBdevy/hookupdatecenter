import AVFoundation
import Foundation
import Darwin
setbuf(stdout, nil)
@MainActor private func run() throws {
    for rate in [44100.0, 48000.0] { for repeated in [false, true] {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode(), chain = NativeEffectsChain(reorderable: false)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        engine.attach(player); chain.attach(to: engine, input: player, format: format)
        engine.connect(chain.output, to: engine.mainMixerNode, format: format)
        var settings = NativeFXSettings()
        let key = settings.appendNative("Pitch", asInstance: repeated)
        func shift(_ st: Int, enabled: Bool = true) {
            var value = settings.settings(for: key)
            value.pitchSemitones = Double(st); value.pitchEnabled = enabled
            settings = settings.merging(effect: key, from: value)
            chain.apply(settings)
        }
        shift(0)
        let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 12))!
        source.frameLength = source.frameCapacity
        for ch in 0..<2 { for n in 0..<Int(source.frameLength) {
            source.floatChannelData![ch][n] = Float(0.08 * sin(2 * .pi * 440 * Double(n) / rate))
        } }
        player.scheduleBuffer(source); try engine.start(); player.play()
        defer { engine.stop() }
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        let nodes = engine.attachedNodes
        let route = nodes.reduce(into: [ObjectIdentifier: [ObjectIdentifier]]()) { result, node in
            result[ObjectIdentifier(node)] = engine.outputConnectionPoints(for: node, outputBus: 0).map { ObjectIdentifier($0.node!) }
        }
        var longestSilence = 0, silence = 0
        for block in 0..<800 {
            switch block {
            case 100: shift(4)
            case 220: shift(0)
            case 340: shift(-3)
            case 460: shift(-3, enabled: false)
            case 580: shift(-3)
            case 700: shift(0)
            default: break
            }
            precondition(engine.attachedNodes == nodes, "Pitch edits must retain the item's nodes")
            for node in nodes {
                precondition(engine.outputConnectionPoints(for: node, outputBus: 0).map { ObjectIdentifier($0.node!) } == route[ObjectIdentifier(node)], "Pitch zero/bypass must not rewire the running graph")
            }
            let status = try engine.renderOffline(512, to: output)
            precondition(status == .success)
            var power = 0.0
            for n in 0..<512 { let v = Double(output.floatChannelData![0][n]); precondition(v.isFinite); power += v*v }
            if block > 80 {
                if sqrt(power/512) < 0.005 { silence += 1; longestSilence = max(longestSilence, silence) } else { silence = 0 }
            }
        }
        print("ITEM_PITCH_ZERO_SHIFT_BYPASS", rate, "instance", repeated, "longest silent blocks", longestSilence)
        precondition(longestSilence < 2, "Pitch toggles interrupted the running item")
    } }
}
try MainActor.assumeIsolated { try run() }
