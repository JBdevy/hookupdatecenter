import AVFoundation
import Foundation

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
precondition(abs(output.floatChannelData![0][100] - 0.1) < 0.00001 &&
             abs(output.floatChannelData![1][100] - 0.2) < 0.00001,
             "The monitor must render the same selected stereo input represented by its meters")
_ = try engine.renderOffline(512, to: output)
precondition((0..<512).allSatisfy { output.floatChannelData![0][$0] == 0 && output.floatChannelData![1][$0] == 0 },
             "No new input must produce silence instead of replaying the previous buffer")
engine.stop()
print("INPUT_METER_BEFORE_RECORDING_MONITOR_CHANNELS_CONSUMED_PEAK_AND_EMPTY_BUFFER_PCM_OK rate=\(rate)")
