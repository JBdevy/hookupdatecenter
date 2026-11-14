import AVFoundation
import Foundation
import Darwin
import ObjectiveC
setbuf(stdout, nil)

func require(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}

// Decoder failures must be repeatable on every supported macOS version. A
// truncated WAV can fail either at open or at read depending on the decoder,
// so this fixture rejects reads for one URL after AVAudioFile has opened it.
private final class AudioReadFailureSwitch {
    private let lock = NSLock()
    private var denied = true
    func allowReads() { lock.lock(); denied = false; lock.unlock() }
    func rejectsReads() -> Bool { lock.lock(); defer { lock.unlock() }; return denied }
}

// Hold a decoder until the render assertions finish. A fixed sleep does not
// reproduce a blocked disk when a loaded CI runner renders more slowly.
private final class AudioReadBlock {
    private let condition = NSCondition()
    private var enabled = false
    private var entered = false
    func enable() { condition.lock(); enabled = true; condition.unlock() }
    func release() {
        condition.lock(); enabled = false; condition.broadcast(); condition.unlock()
    }
    func waitIfEnabled() {
        condition.lock(); defer { condition.unlock() }
        if enabled { entered = true }
        while enabled { condition.wait() }
    }
    var didBlock: Bool {
        condition.lock(); defer { condition.unlock() }; return entered
    }
}

private typealias AudioReadImplementation = @convention(c) (
    AVAudioFile, Selector, AVAudioPCMBuffer, AVAudioFrameCount,
    AutoreleasingUnsafeMutablePointer<NSError?>?
) -> Bool

private func withRejectedAudioReads(at url: URL, body: (AudioReadFailureSwitch) throws -> Void) rethrows {
    let selector = NSSelectorFromString("readIntoBuffer:frameCount:error:")
    let method = class_getInstanceMethod(AVAudioFile.self, selector)!
    let original = method_getImplementation(method)
    let read = unsafeBitCast(original, to: AudioReadImplementation.self)
    let failure = AudioReadFailureSwitch()
    let replacement: @convention(block) (
        AVAudioFile, AVAudioPCMBuffer, AVAudioFrameCount,
        AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool = { file, buffer, count, error in
        if file.url == url && failure.rejectsReads() {
            error?.pointee = NSError(domain: "CatLive.PreparedAudio.Test", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "Injected decoder read failure"])
            return false
        }
        return read(file, selector, buffer, count, error)
    }
    let implementation = imp_implementationWithBlock(replacement)
    method_setImplementation(method, implementation)
    defer {
        failure.allowReads()
        method_setImplementation(method, original)
        // Keep this one test block alive until process exit: a decoder worker
        // may already have fetched its IMP when the original is restored.
    }
    try body(failure)
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

    for block: AVAudioFrameCount in [64, 128, 512] {
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
        // Neutral warming keeps FFT/history available without running phase
        // prediction for dry PCM. Both the first real stretch and its return
        // to unity must remain audible, stereo aligned and pitch preserving.
        for speed in [1.25, 1.0] {
            source.setRate(speed, pitch: 0)
            var transition: [Float] = []
            while transition.count < Int(sampleRate * 0.6) {
                let block = render()
                require(block.map(abs).max()! > 0.02, "Neutral-to-stretched transition introduced a silent block")
                transition += block
            }
            let settled = Array(transition.dropFirst(Int(sampleRate * 0.4)))
            let crossings = zip(settled, settled.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
            let frequency = Double(crossings) * sampleRate / Double(settled.count)
            print("PREPARED_LIVE_TRANSITION", sampleRate, block, speed, frequency)
            require(abs(frequency - 440) < 10, "Live rate transition changed the musical pitch")
        }
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

// Many stems must keep independent rolling lookahead. Use exact dry PCM at a
// high source speed so each stream crosses its initial pages in under a second.
do {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let engine = AVAudioEngine()
    let sources = (0..<24).map { _ in JarasPreparedClip(format: format) }
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    for source in sources {
        engine.attach(source.node)
        engine.connect(source.node, to: engine.mainMixerNode, format: format)
        try source.prepare(directory.appendingPathComponent("source-48000.wav"), sourceFrame: 0,
                           endFrame: 480000, rate: 8, pitch: 36, loopStart: 0, loopEnd: 0)
    }
    try engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: 512)
    try engine.start()
    sources.forEach { $0.start(atHostTime: 0, ramp: false) }
    for block in 0..<100 {
        var status: OSStatus = 0; output.frameLength = 512
        require(engine.manualRenderingBlock(512, output.mutableAudioBufferList, &status) == .success && status == 0,
                "Multi-stem render failed")
        for n in 0..<512 {
            let frame = Double((block * 512 + n) * 8)
            let expected = Float(sources.count) * 0.25 * Float(cos(frame / 48000 * 2 * .pi * 440))
            require(abs(output.floatChannelData![0][n] - expected) < 0.00002,
                    "Rolling prefetch skipped/stalled a stem")
        }
        Thread.sleep(forTimeInterval: 512.0 / 48000)
    }
    require(sources.allSatisfy { $0.underruns == 0 }, "Multi-stem lookahead starved")
    sources.forEach { $0.stop() }; engine.stop()
    print("PREPARED_CLIP_MULTI_STEM_PREFETCH_OK")
}

// At 192 kHz and 32x source speed the warm spectral cursor is more than six
// physical pages ahead of dry playback. The worker must retain/fill that whole
// window, rather than reverting to its old fixed six-page limit after prepare.
do {
    let sampleRate = 192000.0, speed = 32.0
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let url = directory.appendingPathComponent("high-source-rate.wav")
    let samples = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate * 16))!
    samples.frameLength = samples.frameCapacity
    for n in 0..<Int(samples.frameLength) {
        samples.floatChannelData![0][n] = 0.1 * Float(cos(Double(n) / sampleRate * 2 * .pi * 220))
        samples.floatChannelData![1][n] = -samples.floatChannelData![0][n]
    }
    do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: samples) }
    let engine = AVAudioEngine(), source = JarasPreparedClip(format: format)
    engine.attach(source.node); engine.connect(source.node, to: engine.mainMixerNode, format: format)
    try source.prepare(url, sourceFrame: 0, endFrame: sampleRate * 16, rate: speed, pitch: 60,
                       loopStart: 0, loopEnd: 0)
    try engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: 512)
    try engine.start(); source.start(atHostTime: 0, ramp: false)
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    for block in 0..<100 {
        var status: OSStatus = 0; output.frameLength = 512
        require(engine.manualRenderingBlock(512, output.mutableAudioBufferList, &status) == .success && status == 0,
                "High source-rate render failed")
        for n in 0..<512 {
            let frame = Int(Double(block * 512 + n) * speed)
            require(abs(output.floatChannelData![0][n] - samples.floatChannelData![0][frame]) < 0.000001,
                    "High-rate prefetch changed dry PCM")
        }
        Thread.sleep(forTimeInterval: 512.0 / sampleRate)
    }
    require(source.underruns == 0, "High-rate FFT lookahead starved")
    source.stop(); engine.stop()
    print("PREPARED_CLIP_HIGH_RATE_LOOKAHEAD_OK")
}

// A newly opened cache can retain the same start/rate/range as the previous
// source while its first read fails. Retrying it must never reuse the previous
// source's successful prime or start stale FFT history/empty PCM.
do {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let engine = AVAudioEngine(), source = JarasPreparedClip(format: format)
    engine.attach(source.node); engine.connect(source.node, to: engine.mainMixerNode, format: format)
    try engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: 512)
    try engine.start()
    defer { source.stop(); engine.stop() }
    let first = directory.appendingPathComponent("source-48000.wav")
    let second = directory.appendingPathComponent("retry-source.wav")
    let samples = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480000)!
    samples.frameLength = samples.frameCapacity
    for n in 0..<Int(samples.frameLength) {
        samples.floatChannelData![0][n] = -0.125
        samples.floatChannelData![1][n] = 0.125
    }
    do { let file = try AVAudioFile(forWriting: second, settings: format.settings); try file.write(from: samples) }
    try source.prepare(first, sourceFrame: 0, endFrame: 480000, rate: 1, pitch: 0, loopStart: 0, loopEnd: 0)
    try withRejectedAudioReads(at: second) { failure in
        for _ in 0..<2 {
            var rejected = false
            do {
                try source.prepare(second, sourceFrame: 0, endFrame: 480000, rate: 1, pitch: 0,
                                   loopStart: 0, loopEnd: 0)
            } catch { rejected = true }
            require(rejected, "A failed replacement cache reused stale successful preparation")
            source.start(atHostTime: 0, ramp: false)
            require(!source.playing, "A failed source preparation was allowed to start")
        }
        failure.allowReads()
        try source.prepare(second, sourceFrame: 0, endFrame: 480000, rate: 1, pitch: 0, loopStart: 0, loopEnd: 0)
        source.start(atHostTime: 0, ramp: false)
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        output.frameLength = 512
        var status: OSStatus = 0
        require(engine.manualRenderingBlock(512, output.mutableAudioBufferList, &status) == .success && status == 0,
                "Retry render failed")
        for n in 0..<512 {
            require(abs(output.floatChannelData![0][n] + 0.125) < 0.000001 &&
                    abs(output.floatChannelData![1][n] - 0.125) < 0.000001,
                    "Recovered preparation replayed stale source PCM")
        }
        require(source.underruns == 0, "Recovered preparation left an empty PCM cache")
    }
    print("PREPARED_CLIP_FAILED_REPLACEMENT_RETRY_OK")
}

// A decoder blocked on one file must not starve a healthy stem.

do {
 let slowURL = directory.appendingPathComponent("slow-source.wav")
 // Keep the file longer than the initial batched lookahead, so this test
 // necessarily requests a new page after the decoder is blocked.
 let originalFile = try AVAudioFile(forReading: directory.appendingPathComponent("source-48000.wav"))
 let samples = AVAudioPCMBuffer(pcmFormat: originalFile.processingFormat, frameCapacity: AVAudioFrameCount(originalFile.length))!
 try originalFile.read(into: samples)
 do {
  let file = try AVAudioFile(forWriting: slowURL, settings: originalFile.processingFormat.settings)
  for _ in 0..<6 { try file.write(from: samples) }
 }
 let gate = AudioReadBlock()
 let selector = NSSelectorFromString("readIntoBuffer:frameCount:error:")
 let method = class_getInstanceMethod(AVAudioFile.self, selector)!
 let original = method_getImplementation(method)
 let read = unsafeBitCast(original, to: AudioReadImplementation.self)
 let replacement: @convention(block) (AVAudioFile, AVAudioPCMBuffer, AVAudioFrameCount, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool = { file, buffer, count, error in
  if file.url == slowURL { gate.waitIfEnabled() }
  return read(file, selector, buffer, count, error)
 }
 method_setImplementation(method, imp_implementationWithBlock(replacement))
 defer { gate.release(); method_setImplementation(method, original) }
 let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
 let engine = AVAudioEngine()
 let slow = JarasPreparedClip(format: format), healthy = JarasPreparedClip(format: format)
 for (source, url) in [(slow, slowURL), (healthy, directory.appendingPathComponent("source-48000.wav"))] {
  engine.attach(source.node); engine.connect(source.node, to: engine.mainMixerNode, format: format)
  let end = source === slow ? 2_880_000.0 : 480_000.0
  try source.prepare(url, sourceFrame: 0, endFrame: end, rate: 8, pitch: 36, loopStart: 0, loopEnd: end)
 }
 try engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: 512)
 try engine.start()
 let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
 gate.enable(); slow.start(atHostTime: 0, ramp: false); healthy.start(atHostTime: 0, ramp: false)
 for _ in 0..<180 {
  var status: OSStatus = 0; output.frameLength = 512
  require(engine.manualRenderingBlock(512, output.mutableAudioBufferList, &status) == .success && status == 0,
          "Blocked-decoder render failed")
  Thread.sleep(forTimeInterval: 512.0 / 48000)
 }
 require(gate.didBlock, "Slow decoder fixture never requested uncached audio")
 require(slow.underruns > 0, "Slow decoder fixture did not exhaust its lookahead")
 require(healthy.underruns == 0, "Blocked decoder starved a healthy stem")
 print("PREPARED_CLIP_BLOCKED_DECODER_ISOLATION_OK")
 gate.release()
 slow.stop(); healthy.stop(); engine.stop()
}
