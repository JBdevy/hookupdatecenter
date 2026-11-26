import AVFoundation
import Foundation
import Darwin
setbuf(stdout, nil)
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-stretch-" + UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
for sampleRate in [44100.0, 48000.0] {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let file = directory.appendingPathComponent("shared-\(sampleRate).wav")
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100000)!
    pcm.frameLength = pcm.frameCapacity
    for n in 0..<Int(pcm.frameLength) {
        for c in 0..<2 {
            let t = Double(n) / sampleRate
            pcm.floatChannelData![c][n] = Float(0.15 * sin(t * (c == 0 ? 440 : 617) * 2 * .pi) +
                0.05 * sin(t * t * 26000) + (n % 593 == 0 ? 0.1 : 0))
        }
    }
    try AVAudioFile(forWriting: file, settings: format.settings).write(from: pcm)
    let sharedEngine = AVAudioEngine(), referenceEngine = AVAudioEngine()
    let timing = JarasPreparedClipTiming(engine: sharedEngine)
    defer { withExtendedLifetime(timing) {} }
    var shared: [JarasPreparedClip] = [], references: [JarasPreparedClip] = []
    var referenceFiles: [URL] = []
    for index in 0..<6 {
        let referenceFile = directory.appendingPathComponent("independent-\(sampleRate)-\(index).wav")
        try FileManager.default.copyItem(at: file, to: referenceFile)
        referenceFiles.append(referenceFile)
        for (engine, url, isShared) in [(sharedEngine, file, true), (referenceEngine, referenceFile, false)] {
            let source = JarasPreparedClip(format: format, timing: isShared ? timing : nil), gain = AVAudioMixerNode()
            engine.attach(source.node); engine.attach(gain)
            engine.connect(source.node, to: gain, format: format)
            engine.connect(gain, to: engine.mainMixerNode, format: format)
            gain.outputVolume = Float(index + 1) / 30
            try source.prepare(url, sourceFrame: 0, endFrame: 1e8, rate: 1, pitch: 0, loopStart: 0, loopEnd: 96000)
            if isShared { shared.append(source) } else { references.append(source) }
        }
    }
    for engine in [sharedEngine, referenceEngine] {
        try engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: 2048)
        try engine.start()
    }
    (shared + references).forEach { $0.start(atHostTime: 0, ramp: false) }
    let a = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048)!
    let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048)!
    var maximumError: Float = 0
    var injected: (Double, Double)? = nil
    var applied: (Double, Double)? = nil
    let observer = shared[0].node.auAudioUnit.token(byAddingRenderObserver: { flags, _, _, _ in
        guard flags.contains(.unitRenderAction_PreRender), let change = injected else { return }
        // Deliberately publish after the mixer latched this render block.
        // This fixture renders synchronously; production edits run on control.
        timing.beginUpdates()
        shared.forEach { $0.setRate(change.0, pitch: change.1) }
        timing.endUpdates()
        applied = change; injected = nil
    })
    defer { shared[0].node.auAudioUnit.removeRenderObserver(observer) }
    for block in 0..<320 {
        if let change = applied {
            references.forEach { $0.setRate(change.0, pitch: change.1) }
            applied = nil
        }
        injected = (1 + Double((block * 7) % 43) / 100, Double(block % 5) - 2)
        let frames: AVAudioFrameCount = [64, 128, 512, 2048][(block / 8) % 4]
        for (engine, output) in [(sharedEngine, a), (referenceEngine, b)] {
            output.frameLength = frames; var status: OSStatus = 0
            precondition(engine.manualRenderingBlock(frames, output.mutableAudioBufferList, &status) == .success && status == 0)
        }
        for ch in 0..<2 { for n in 0..<Int(frames) {
            let error = abs(a.floatChannelData![ch][n] - b.floatChannelData![ch][n])
            maximumError = max(maximumError, error)
            precondition(error < 0.000002, "Shared DSP changed independent audio: rate=\(sampleRate) block=\(block) error=\(error)")
        } }
        for i in shared.indices {
            precondition(abs(shared[i].sourcePosition - references[i].sourcePosition) < 1e-9)
        }
    }
    precondition((shared + references).allSatisfy { $0.underruns == 0 })
    (shared + references).forEach { $0.stop() }
    sharedEngine.stop(); referenceEngine.stop()
    print("SHARED_STRETCH_MID_RENDER_BPM_PARITY rate=\(sampleRate) maxError=\(maximumError) rapidRatesDuringGraphPull=OK")
}
