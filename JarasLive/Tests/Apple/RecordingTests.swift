import Foundation
import AVFoundation
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: directory) }
let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4)!)
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
buffer.frameLength = 48000
for channel in 0..<4 { for frame in 0..<48000 { buffer.floatChannelData![channel][frame] = Float(channel + 1) * 0.1 * sin(Float(frame) * 2 * .pi * 440 / 48000) } }
let overflow = JarasCaptureRing(channels: 4, capacity: 100)
overflow.push(buffer)
precondition(overflow.droppedFrames == 47900, "overflow must be reported")
let stereo = UUID(), mono = UUID(), mp3 = UUID(), floatWav = UUID()
let writer = try CaptureWriter(targets: [CaptureTarget(track: stereo, input: OutputPatch(firstChannel: 3, channelCount: 2), format: "wav"), CaptureTarget(track: mono, input: OutputPatch(firstChannel: 1, channelCount: 1), format: "wav"), CaptureTarget(track: mp3, input: .stereo, format: "mp3"), CaptureTarget(track: floatWav, input: OutputPatch(firstChannel: 3, channelCount: 2), format: "wav32")], directory: directory, format: format)
let previewed = DispatchSemaphore(value: 0)
writer.start { duration, waveforms in
    precondition(duration == 1, "live preview follows captured frames")
    precondition(waveforms[stereo]?.count == 2 && waveforms[mono]?.count == 1, "live waveform preserves stereo and mono")
    precondition((waveforms[stereo]?[0].max() ?? 0) > 0.29, "waveform appears before Stop")
    previewed.signal()
}
writer.ring.push(buffer)
precondition(previewed.wait(timeout: .now()+3) == .success, "recording must publish a growing item before finalization")
let completed = DispatchSemaphore(value: 0)
writer.finish(start: 30) { items, error in
    precondition(error == nil, "recording writer failed: \(error ?? "")")
    precondition(items.count == 4, "every armed track gets its own recording")
    for item in items {
        precondition(item.clip.startTime == 30 && item.clip.duration == 1, "take keeps timeline position and duration")
        let url = directory.appendingPathComponent(item.clip.audioFile!.path)
        let file = try! AVAudioFile(forReading: url)
        if item.track != mp3 {
            precondition(file.fileFormat.streamDescription.pointee.mBitsPerChannel == (item.track == floatWav ? 32 : 24), "WAV bit depth follows the chosen recording format")
            if item.track == floatWav { precondition(file.fileFormat.streamDescription.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0, "32-bit WAV must contain floating-point PCM") }
            precondition(file.processingFormat.channelCount == (item.track == mono ? 1 : 2), "input patch defines take channel count")
            let output = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024)!
            try! file.read(into: output, frameCount: 1024)
            let peak = (0..<1024).map { abs(output.floatChannelData![0][$0]) }.max()!
            precondition(abs(peak - (item.track == mono ? 0.1 : 0.3)) < 0.001, "input channel mapping must preserve PCM")
        } else {
            let bytes = [UInt8](try! Data(contentsOf: url))
            let header = (0..<min(bytes.count - 4, 4096)).first { bytes[$0] == 0xff && bytes[$0 + 1] & 0xe0 == 0xe0 && bytes[$0 + 2] >> 4 == 14 }
            precondition(header != nil, "MP3 must use 320 kbps")
            precondition(file.processingFormat.channelCount == 2, "MP3 preserves stereo")
        }
    }
    print("RECORDING_24BIT_32FLOAT_ROUTING_AND_MP3_OK")
    completed.signal()
}
precondition(completed.wait(timeout: .now() + 30) == .success, "recording finalization must complete")

let empty = try CaptureWriter(targets: [CaptureTarget(track: UUID(),input: .stereo,format: "wav")],directory: directory,format: format)
let emptyFinished = DispatchSemaphore(value: 0)
empty.start()
empty.finish(start: 0) { items,error in
    precondition(items.isEmpty && error != nil,"missing input must report an error instead of creating a successful empty take")
    emptyFinished.signal()
}
precondition(emptyFinished.wait(timeout: .now()+3) == .success,"empty take finalization completes")
let wavs = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Stems/Recordings"),includingPropertiesForKeys: nil).filter { $0.pathExtension == "wav" }
precondition(wavs.count == 3,"a take without audio must not leave an empty WAV")
print("RECORDING_MISSING_INPUT_HANDLED_OK")

// The installed input tap keeps feeding the same ring while playback continues.
// Stop must gate those buffers, and a later take must start from a clean ring.
let reusable = JarasCaptureRing(channels: 4, capacity: 96000)
for take in 0..<3 {
    let captured = DispatchSemaphore(value: 0)
    let writer = try CaptureWriter(targets: [CaptureTarget(track: stereo, input: .stereo, format: "wav")], directory: directory, format: format, ring: reusable)
    writer.start()
    reusable.push(buffer)
    writer.finish(start: Double(take) * 2) { items, error in
        precondition(error == nil && items.count == 1, "each reused capture creates one complete take")
        precondition(items[0].clip.duration == 1, "stopping capture excludes later input buffers and previous takes")
        captured.signal()
    }
    for _ in 0..<4 { reusable.push(buffer) }
    precondition(captured.wait(timeout: .now() + 3) == .success, "capture finishes without removing the live input tap")
}
let stoppedRing = JarasCaptureRing(channels: 4, capacity: 96000)
let producerFinished = DispatchSemaphore(value: 0)
DispatchQueue.global(qos: .userInteractive).async {
    for _ in 0..<60 { stoppedRing.push(buffer) }
    producerFinished.signal()
}
stoppedRing.endCapture()
stoppedRing.waitForPendingCapture()
var samples = Array(repeating: Float.zero, count: 96000 * 4)
let accepted = samples.withUnsafeMutableBufferPointer { stoppedRing.readFrames($0.baseAddress!, maximum: 96000) }
precondition(producerFinished.wait(timeout: .now() + 3) == .success, "realtime producer never blocks on recording stop")
let late = samples.withUnsafeMutableBufferPointer { stoppedRing.readFrames($0.baseAddress!, maximum: 96000) }
precondition(late == 0 && accepted % 48000 == 0, "stop drains complete accepted buffers without a late write")
print("RECORDING_STOP_GATE_REUSE_AND_CONCURRENT_PRODUCER_OK")
// Independent arming while global REC stays active, including zero targets.
let dynamic = try CaptureWriter(targets: [], directory: directory, format: format)
let a = CaptureTarget(track: UUID(), input: .stereo, format: "wav", lane: 4)
let b = CaptureTarget(track: UUID(), input: .stereo, format: "wav", lane: 2)
let disarmed = DispatchSemaphore(value: 0), final = DispatchSemaphore(value: 0)
dynamic.start()
dynamic.changeTargets([a,b], position: 40) { _,_ in }
// Queue operations finish before writing the first input block.
Thread.sleep(forTimeInterval: 0.08)
dynamic.ring.push(buffer)
Thread.sleep(forTimeInterval: 0.08)
dynamic.changeTargets([b], position: 41) { items,error in
    precondition(error == nil && items.count == 1 && items[0].track == a.track)
    precondition(items[0].clip.startTime == 40 && items[0].clip.duration == 1 && items[0].clip.recordingLane == 4)
    disarmed.signal()
}
precondition(disarmed.wait(timeout: .now()+3) == .success)
dynamic.ring.push(buffer)
dynamic.finish(start: 40) { items,error in
    precondition(error == nil && items.count == 1 && items[0].track == b.track)
    precondition(items[0].clip.duration == 2 && items[0].clip.startTime == 40)
    final.signal()
}
precondition(final.wait(timeout: .now()+3) == .success)
print("RECORDING_EMPTY_REC_DYNAMIC_ARM_DISARM_AND_CONTINUOUS_OTHER_TRACK_OK")

for formatKey in ["wav24pcm", "wav32pcm", "aiff24pcm", "aiff32pcm", "mp3-128", "mp3-320"] {
    let target = CaptureTarget(track: UUID(), input: .stereo, format: formatKey)
    let take = try CaptureWriter(targets: [target], directory: directory, format: format)
    take.start(); take.ring.push(buffer)
    let done = DispatchSemaphore(value: 0)
    take.finish(start: 5) { items, error in
        precondition(error == nil && items.count == 1)
        let url = directory.appendingPathComponent(items[0].clip.audioFile!.path)
        let audio = try! AVAudioFile(forReading: url)
        if !formatKey.hasPrefix("mp3") {
            let description = audio.fileFormat.streamDescription.pointee
            precondition(description.mBitsPerChannel == (formatKey.contains("32") ? 32 : 24))
            precondition(description.mFormatFlags & kAudioFormatFlagIsFloat == 0, "new recordings use integer PCM")
            precondition(url.pathExtension == (formatKey.hasPrefix("aiff") ? "aiff" : "wav"))
        }
        done.signal()
    }
    precondition(done.wait(timeout: .now() + 10) == .success)
}
print("RECORD_GLOBAL_WAV_AIFF_24_32_INTEGER_PCM_AND_MP3_128_320_OK")

let outputModes = try CaptureWriter(targets: [
    CaptureTarget(track: UUID(), input: OutputPatch(firstChannel: 3, channelCount: 2), format: "wav", recordedChannels: 1),
    CaptureTarget(track: UUID(), input: OutputPatch(firstChannel: 2, channelCount: 1), format: "wav", recordedChannels: 2)
], directory: directory, format: format)
outputModes.start { _, _ in }
outputModes.ring.push(buffer)
let outputDone = DispatchSemaphore(value: 0)
outputModes.finish(start: 0) { items, error in
    precondition(error == nil && items.count == 2)
    for item in items {
        let file = try! AVAudioFile(forReading: directory.appendingPathComponent(item.clip.audioFile!.path))
        let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48000)!
        try! file.read(into: pcm)
        if file.processingFormat.channelCount == 1 {
            precondition(abs(pcm.floatChannelData![0][20] - buffer.floatChannelData![2][20]) < 0.00001)
        } else {
            precondition(file.processingFormat.channelCount == 2)
            precondition(abs(pcm.floatChannelData![0][20] - buffer.floatChannelData![1][20]) < 0.00001)
            precondition(pcm.floatChannelData![0][20] == pcm.floatChannelData![1][20])
        }
    }
    outputDone.signal()
}
precondition(outputDone.wait(timeout: .now()+5) == .success)
print("RECORDING_OUTPUT_MODE_INDEPENDENT_OF_INPUT_PATCH_OK")
