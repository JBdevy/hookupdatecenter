import AVFoundation
import Foundation
import Darwin

setbuf(stdout, nil)
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-sync-" + UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }

// Use RemoteIO's actual render entry point with a deterministic hardware clock.
// Independent control-thread preparation must not advance any stem before the
// common deadline, even after Stop/Play, seeks and repeated queued transitions.
for rate in [44100.0, 48000.0] {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let url = directory.appendingPathComponent("source-\(Int(rate)).wav")
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
    pcm.frameLength = pcm.frameCapacity
    for frame in 0..<Int(pcm.frameLength) {
        let value = Float(0.2 + 0.05 * sin(Double(frame) * 0.017))
        pcm.floatChannelData![0][frame] = value
        pcm.floatChannelData![1][frame] = -value
    }
    do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: pcm) }
    for block: AVAudioFrameCount in [128, 512] {
        let engine = AVAudioEngine(), driver = JarasMobileAudioOutput(engine: engine)
        _ = try driver.configure(withSampleRate: rate, channels: 2)
        let sources = (0..<8).map { _ in JarasPreparedClip(format: format) }
        for source in sources { engine.attach(source.node); engine.connect(source.node, to: engine.mainMixerNode, format: format) }
        engine.mainMixerNode.outputVolume = 1 / Float(sources.count)
        try engine.start(); try driver.start()
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block)!
        output.frameLength = block
        let base = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 10)
        func host(_ frame: Int64) -> UInt64 { base + AVAudioTime.hostTime(forSeconds: Double(frame) / rate) }
        func render() -> [Float] {
            var time = AudioTimeStamp()
            time.mSampleTime = Double(engine.manualRenderingSampleTime)
            time.mHostTime = host(engine.manualRenderingSampleTime)
            time.mFlags = [.sampleTimeValid, .hostTimeValid]
            var flags = AudioUnitRenderActionFlags()
            precondition(driver.renderFrames(block, time: &time, flags: &flags, buffers: output.mutableAudioBufferList) == noErr)
            return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(block)))
        }
        for transition in 0..<12 {
            sources.forEach { $0.stop() }
            precondition(render().allSatisfy { abs($0) < 0.000001 }, "Stop leaked old PCM")
            let first = Double(transition * 137)
            // Advance the physical callback between preparing individual stems.
            for source in sources {
                try source.prepare(url, sourceFrame: first, endFrame: rate, rate: 1, pitch: 0, loopStart: 0, loopEnd: 0)
                precondition(render().allSatisfy { abs($0) < 0.000001 }, "Preparation played a stem")
            }
            let deadline = engine.manualRenderingSampleTime + Int64(block * 3) + 37
            for source in sources { source.start(atHostTime: host(deadline), ramp: false) }
            var captured: [Float] = []
            let start = engine.manualRenderingSampleTime
            for _ in 0..<7 { captured += render() }
            let onset = captured.firstIndex { abs($0) > 0.01 }
            precondition(onset != nil && abs(Int64(onset!) - (deadline - start)) <= 1,
                         "Mobile source ignored the physical deadline: onset=\(String(describing: onset)), expected=\(deadline - start)")
            let positions = sources.map(\.sourcePosition)
            precondition(positions.max()! - positions.min()! < 0.5 / rate, "Stems diverged after transition \(transition)")
            for offset in 0..<min(128, captured.count - onset!) {
                precondition(abs(captured[onset! + offset] - pcm.floatChannelData![0][Int(first) + offset]) < 0.00001,
                             "A stem skipped or repeated samples at transition \(transition)")
            }
            precondition(sources.allSatisfy { $0.underruns == 0 }, "Prepared source starved")
        }
        driver.stop(); engine.stop()
        print("MOBILE_PREPARED_SYNC_OK rate=\(rate) buffer=\(block) stems=8 transitions=12")
    }
}
