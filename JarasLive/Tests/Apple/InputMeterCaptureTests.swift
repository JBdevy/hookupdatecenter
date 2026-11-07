import AVFoundation
import Foundation
setbuf(stdout, nil)

let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
let inputFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 512)!
input.frameLength = 512
for channel in 0..<2 {
    input.floatChannelData![channel].initialize(repeating: Float(channel + 1) / 10, count: 512)
}
let ring = JarasCaptureRing(channels: 2, capacity: 4096)
ring.endCapture()
ring.push(input)
precondition(abs(ring.takeInputPeak(0) - 0.1) < 0.00001 && abs(ring.takeInputPeak(1) - 0.2) < 0.00001,
             "The selected input channels must meter before recording starts, independently of Monitor On/Off")
precondition(ring.takeInputPeak(0) == 0 && ring.takeInputPeak(1) == 0,
             "Reading an input peak must consume it, so an idle source cannot leave a stale meter")
var captured = [Float](repeating: 0, count: 2048)
let stoppedFrames = captured.withUnsafeMutableBufferPointer { ring.readFrames($0.baseAddress!, maximum: 512) }
precondition(stoppedFrames == 0, "Metering a stopped input must not create a recording")

let engine = AVAudioEngine()
let outputFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
try engine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 512)
let source = ring.monitorSource(withSampleRate: rate, firstChannel: 0, channelCount: 2)
engine.attach(source)
engine.connect(source, to: engine.mainMixerNode, format: outputFormat)
let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 512)!
ring.beginCapture(); ring.push(input)
try engine.start()
let status = try engine.renderOffline(512, to: output)
precondition(status == .success)
precondition((0..<512).allSatisfy { output.floatChannelData![0][$0] == 0 },
             "Monitoring must prime a scheduling reserve before playing asynchronous input")
ring.push(input)
_ = try engine.renderOffline(512, to: output)
precondition(abs(output.floatChannelData![0][100] - 0.1) < 0.00001 &&
             abs(output.floatChannelData![1][100] - 0.2) < 0.00001,
             "The monitor must render the same selected stereo input represented by its meters")
_ = try engine.renderOffline(512, to: output)
_ = try engine.renderOffline(512, to: output)
precondition((0..<512).allSatisfy { output.floatChannelData![0][$0] == 0 && output.floatChannelData![1][$0] == 0 },
             "No new input must produce silence instead of replaying the previous buffer")
ring.push(input)
_ = try engine.renderOffline(512, to: output)
precondition(output.floatChannelData![0][100] == 0, "After starvation, rebuild the reserve before resuming")
ring.push(input)
_ = try engine.renderOffline(512, to: output)
precondition(abs(output.floatChannelData![0][100] - 0.1) < 0.00001, "New input resumes after an interruption")
for _ in 0..<12 { ring.push(input) }
precondition(ring.droppedFrames > 0, "Simulate a device pause long enough to fill the bounded queue")
for _ in 0..<2 {
    _ = try engine.renderOffline(512, to: output)
    precondition(abs(output.floatChannelData![0][100] - 0.1) < 0.00001)
}
_ = try engine.renderOffline(512, to: output)
precondition(output.floatChannelData![0][100] == 0, "A paused output must discard excess stale latency")
engine.stop()
print("INPUT_METER_BEFORE_RECORDING_MONITOR_CHANNELS_CONSUMED_PEAK_AND_EMPTY_BUFFER_PCM_OK rate=\(rate)")

// The capture tap and the headphone renderer run independently. A requested
// tap size is not a promise that input will arrive in equally small blocks.
// Feed the production ring in batches while rendering at the output clock.
func batchedMonitor(inputFrames: Int, outputFrames: Int, jitter: Bool, outputRate: Double = rate) throws {
    let engine = AVAudioEngine()
    let renderFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)!
    try engine.enableManualRenderingMode(.offline, format: renderFormat,
                                        maximumFrameCount: AVAudioFrameCount(outputFrames))
    let ring = JarasCaptureRing(channels: 2, capacity: UInt(max(16384, Int(rate / 2))))
    let source = ring.monitorSource(withSampleRate: rate, firstChannel: 0, channelCount: 2)
    engine.attach(source); engine.connect(source, to: engine.mainMixerNode, format: outputFormat)
    let batch = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(inputFrames))!
    batch.frameLength = batch.frameCapacity
    for channel in 0..<2 {
        batch.floatChannelData![channel].initialize(repeating: Float(channel + 1) / 10, count: inputFrames)
    }
    let output = AVAudioPCMBuffer(pcmFormat: renderFormat, frameCapacity: AVAudioFrameCount(outputFrames))!
    try engine.start()
    defer { engine.stop() }
    var inputNumber = 0, missing = 0
    let warmup = max(inputFrames, outputFrames) * 4
    for position in stride(from: 0, to: Int(outputRate * 3), by: outputFrames) {
        let inputPosition = Double(position) * rate / outputRate
        while true {
            let delay = jitter && inputNumber % 3 == 1 ? min(inputFrames, outputFrames) / 3 : 0
            guard Double(inputNumber * inputFrames + delay) <= inputPosition else { break }
            ring.push(batch); inputNumber += 1
        }
        let status = try engine.renderOffline(AVAudioFrameCount(outputFrames), to: output)
        precondition(status == .success)
        if inputPosition >= Double(warmup) {
            for frame in 0..<outputFrames {
                if abs(output.floatChannelData![0][frame] - 0.1) > 0.00001 ||
                   abs(output.floatChannelData![1][frame] - 0.2) > 0.00001 { missing += 1 }
            }
        }
    }
    print("MONITOR_BATCH input=\(inputFrames) output=\(outputFrames) rates=\(rate)/\(outputRate) jitter=\(jitter) missing=\(missing)")
    precondition(missing == 0, "A continuously arriving microphone must not be chopped between capture batches")
    precondition(ring.droppedFrames == 0, "Normal asynchronous monitoring must not overflow its input queue")
}
try batchedMonitor(inputFrames: 4800, outputFrames: 512, jitter: true, outputRate: rate == 48000 ? 44100 : 48000)
try batchedMonitor(inputFrames: 256, outputFrames: 128, jitter: true, outputRate: rate == 48000 ? 44100 : 48000)
for (inputFrames, outputFrames) in [(4800, 512), (4410, 128), (8192, 1024), (256, 512), (512, 128), (512, 512)] {
    try batchedMonitor(inputFrames: inputFrames, outputFrames: outputFrames, jitter: false)
    try batchedMonitor(inputFrames: inputFrames, outputFrames: outputFrames, jitter: true)
}

// Small hardware input blocks must not acquire a fixed 4096-frame monitoring
// delay. At matching clocks, one callback of reserve is enough after priming.
for quantum: AVAudioFrameCount in [64, 128, 512, 1024] {
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: quantum)
    let ring = JarasCaptureRing(channels: 2, capacity: UInt(rate / 2))
    let source = ring.monitorSource(withSampleRate: rate, firstChannel: 0, channelCount: 2)
    engine.attach(source); engine.connect(source, to: engine.mainMixerNode, format: outputFormat)
    let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: quantum)!
    let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: quantum)!
    input.frameLength = quantum
    for ch in 0..<2 { input.floatChannelData![ch].initialize(repeating: 0.25, count: Int(quantum)) }
    try engine.start()
    for block in 0..<8 {
        ring.push(input)
        let status = try engine.renderOffline(quantum, to: output)
        precondition(status == .success)
        if block >= 1 {
            for sample in 0..<Int(quantum) {
                precondition(abs(output.floatChannelData![0][sample] - 0.25) < 0.00001,
                             "Small-buffer monitoring gained hidden delay or lost continuous input")
            }
        }
    }
    engine.stop()
    print("MONITOR_HARDWARE_QUANTUM_LOW_LATENCY_OK rate=\(rate) buffer=\(quantum)")
}
