import AVFoundation
import Foundation
import Darwin
import ObjectiveC
setbuf(stdout, nil)

private typealias AudioReadImplementation = @convention(c) (AVAudioFile, Selector, AVAudioPCMBuffer, AVAudioFrameCount, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
private final class StorageLatency {
    private let lock = NSLock()
    private var active = false
    private var reads = 0
    private var largest: UInt32 = 0
    func start() { lock.lock(); active = true; lock.unlock() }
    func beforeRead(_ count: UInt32) {
        lock.lock()
        let delay = active
        if delay { reads += 1; largest = max(largest, count) }
        lock.unlock()
        // Each operation is delayed, while its transfer remains fast: a
        // latency-bound storage path, not a low sequential bandwidth limit.
        if delay { Thread.sleep(forTimeInterval: 0.15) }
    }
    var statistics: (Int, UInt32) { lock.lock(); defer { lock.unlock() }; return (reads, largest) }
}

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-storage-latency-" + UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
let url = directory.appendingPathComponent("continuous.wav")
let samples = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000 * 30)!
samples.frameLength = samples.frameCapacity
for n in 0..<Int(samples.frameLength) {
    samples.floatChannelData![0][n] = 0.005 * Float(cos(Double(n) / 48000 * 2 * .pi * 330))
    samples.floatChannelData![1][n] = -samples.floatChannelData![0][n]
}
do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: samples) }
private let gate = StorageLatency()
let selector = NSSelectorFromString("readIntoBuffer:frameCount:error:")
let method = class_getInstanceMethod(AVAudioFile.self, selector)!
let original = method_getImplementation(method)
private let read = unsafeBitCast(original, to: AudioReadImplementation.self)
let replacement: @convention(block) (AVAudioFile, AVAudioPCMBuffer, AVAudioFrameCount, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool = { file, buffer, count, error in
    if file.url == url { gate.beforeRead(count) }
    return read(file, selector, buffer, count, error)
}
method_setImplementation(method, imp_implementationWithBlock(replacement))
defer { method_setImplementation(method, original) }
let engine = AVAudioEngine()
let sources = (0..<24).map { _ in JarasPreparedClip(format: format) }
for source in sources {
    engine.attach(source.node); engine.connect(source.node, to: engine.mainMixerNode, format: format)
    try source.prepare(url, sourceFrame: 0, endFrame: 48000 * 30, rate: 1, pitch: 0, loopStart: 0, loopEnd: 0)
}
try engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: 512)
try engine.start()
let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
gate.start(); sources.forEach { $0.start(atHostTime: 0, ramp: false) }
let start = ProcessInfo.processInfo.systemUptime
var maxError: Float = 0
let blocks = 1125 // 12 seconds, long enough to exhaust the initial PCM reserve.
for block in 0..<blocks {
    var status: OSStatus = 0; output.frameLength = 512
    precondition(engine.manualRenderingBlock(512, output.mutableAudioBufferList, &status) == .success && status == 0)
    for n in 0..<512 {
        let expected = Float(sources.count) * samples.floatChannelData![0][block * 512 + n]
        maxError = max(maxError, abs(output.floatChannelData![0][n] - expected), abs(output.floatChannelData![1][n] + expected))
    }
    let wait = start + Double((block + 1) * 512) / 48000 - ProcessInfo.processInfo.systemUptime
    if wait > 0 { Thread.sleep(forTimeInterval: wait) }
}
let elapsed = ProcessInfo.processInfo.systemUptime - start
let misses = sources.map(\.underruns).reduce(0, +)
let stats = gate.statistics
sources.forEach { $0.stop() }; engine.stop()
print("STORAGE_LATENCY_24_STEMS readDelayMs=150 seconds=\(elapsed) readCalls=\(stats.0) largestReadFrames=\(stats.1) underruns=\(misses) maxError=\(maxError)")
precondition(misses == 0 && maxError < 0.00001, "Latency-bound storage exhausted the PCM reserve or changed audio")
print("STORAGE_LATENCY_24_STEMS_EXACT_PCM_NO_DROPOUT_OK")
