import AVFoundation
import Foundation
import Darwin
setbuf(stdout, nil)

func require(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("prepared-clip-" + UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }

for sampleRate in [44100.0, 48000.0] {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let url = directory.appendingPathComponent("source-\(Int(sampleRate)).wav")
    let samples = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate * 10))!
    samples.frameLength = samples.frameCapacity
    for i in 0..<Int(samples.frameLength) {
        samples.floatChannelData![0][i] = 0.25 * Float(cos(Double(i) / sampleRate * 2 * .pi * 440))
        samples.floatChannelData![1][i] = -samples.floatChannelData![0][i]
    }
    do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: samples) }

    for block: AVAudioFrameCount in [64, 512] {
        let engine = AVAudioEngine()
        let source = JarasPreparedClip(format: format)
        engine.attach(source.node)
        engine.connect(source.node, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: block)
        try engine.start()
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block)!
        func render() -> [Float] {
            var status: OSStatus = 0
            output.frameLength = block
            let result = engine.manualRenderingBlock(block, output.mutableAudioBufferList, &status)
            if result != .success || status != 0 { print("RENDER_STATUS", result.rawValue, status); fflush(stdout) }
            require(result == .success && status == 0, "Render failed")
            for n in 0..<Int(block) {
                require(abs(output.floatChannelData![0][n] + output.floatChannelData![1][n]) < 0.001,
                        "Source changed stereo polarity/alignment")
            }
            return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(block)))
        }
        for (speed, pitch) in [(1.0, 0.0), (1.25, 0.0), (1.0, 12.0)] {
            print("CASE", sampleRate, block, speed, pitch)
            try source.prepare(url, sourceFrame: 0, endFrame: sampleRate * 4, rate: speed, pitch: pitch, loopStart: 0, loopEnd: 0)
            source.start(atHostTime: 0, ramp: false)
            var recorded: [Float] = []
            while recorded.count < Int(sampleRate * 0.4) { recorded += render() }
            require(recorded.prefix(Int(sampleRate * 0.005)).map(abs).max()! > 0.1,
                    "Prepared source retained startup processing silence")
            let settled = Array(recorded.dropFirst(Int(sampleRate * 0.08)))
            let crossings = zip(settled, settled.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
            let frequency = Double(crossings) * sampleRate / Double(settled.count)
            let expected = pitch == 12 ? 880.0 : 440.0
            require(abs(frequency - expected) < 6, "Rate/pitch changed the wrong musical frequency")
            require(source.underruns == 0, "Prepared PCM cache starved")
            if speed == 1 && pitch == 0 {
                for i in recorded.indices {
                    require(abs(recorded[i] - samples.floatChannelData![0][i]) < 0.000001,
                            "Unity playback must preserve original PCM")
                }
            }
            source.stop()
            require(render().allSatisfy { abs($0) < 0.00001 }, "Stop leaked source audio")
            print("PREPARED_CLIP rate=\(sampleRate) buffer=\(block) speed=\(speed) pitch=\(pitch) measuredHz=\(frequency)")
        }
        // Reusing a source after a seek must not retain the old spectral history.
        let first = 9876.0
        try source.prepare(url, sourceFrame: first, endFrame: sampleRate * 4, rate: 1, pitch: 0, loopStart: 0, loopEnd: 0)
        source.start(atHostTime: 0, ramp: false)
        let sought = render()
        require(abs(sought[0] - samples.floatChannelData![0][Int(first)]) < 0.000001, "Seek replayed stale PCM")
        let before = source.sourcePosition
        source.setRate(1.25, pitch: 0)
        _ = render()
        require(abs(source.sourcePosition - before - Double(block) * 1.25 / sampleRate) < 0.0000001,
                "Live BPM change lost the source position")
        source.stop(); engine.stop()
    }
}
// Cross several cache generations, then a non-page-aligned loop boundary.
// The two boundary pages deliberately collide in an eight-slot modulo cache.
let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
let source = JarasPreparedClip(format: format), engine = AVAudioEngine()
engine.attach(source.node); engine.connect(source.node, to: engine.mainMixerNode, format: format)
try engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: 512)
try engine.start()
let loopStart = 9876.0, loopEnd = Double(8 * 32768 + 12345)
let first = loopEnd - 256
try source.prepare(directory.appendingPathComponent("source-48000.wav"), sourceFrame: first,
                   endFrame: 2_000_000, rate: 1, pitch: 0, loopStart: loopStart, loopEnd: loopEnd)
source.start(atHostTime: 0, ramp: false)
let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
for block in 0..<700 {
    var status: OSStatus = 0; output.frameLength = 512
    require(engine.manualRenderingBlock(512, output.mutableAudioBufferList, &status) == .success && status == 0,
            "Stream render failed")
    for n in 0..<512 {
        let unwrapped = first + Double(block * 512 + n)
        let index = loopStart + (unwrapped - loopStart).truncatingRemainder(dividingBy: loopEnd - loopStart)
        let expected = 0.25 * Float(cos(index / 48000 * 2 * .pi * 440))
        require(abs(output.floatChannelData![0][n] - expected) < 0.000001,
                "Stream/loop cache changed original PCM")
    }
    // Pace the callback as hardware would, leaving the decoder its real budget.
    Thread.sleep(forTimeInterval: 512.0 / 48000)
}
require(source.underruns == 0, "Streaming or loop lookahead starved")
source.stop(); engine.stop()
print("PREPARED_CLIP_STREAM_AND_LOOP_OK")
print("PREPARED_CLIP_PCM_PITCH_RATE_STOP_SEEK_OK")
