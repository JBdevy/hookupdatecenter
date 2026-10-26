import Foundation
import AVFoundation
import AppKit
setbuf(stdout, nil)
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
let writer = try CaptureWriter(targets: [CaptureTarget(track: stereo, input: OutputPatch(firstChannel: 3, channelCount: 2), format: "wav", name: "Capture - 001"), CaptureTarget(track: mono, input: OutputPatch(firstChannel: 1, channelCount: 1), format: "wav", name: "Capture - 002"), CaptureTarget(track: mp3, input: .stereo, format: "mp3", name: "Capture - 003"), CaptureTarget(track: floatWav, input: OutputPatch(firstChannel: 3, channelCount: 2), format: "wav32", name: "Capture - 004")], directory: directory, format: format)
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

let empty = try CaptureWriter(targets: [CaptureTarget(track: UUID(),input: .stereo,format: "wav", name: "Capture - 005")],directory: directory,format: format)
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
    let writer = try CaptureWriter(targets: [CaptureTarget(track: stereo, input: .stereo, format: "wav", name: "Repeated - \(take)")], directory: directory, format: format, ring: reusable)
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

// Overflow reports a partial take, preserving every PCM frame accepted by
// the real bridge ring. A later armed track and a new session must not inherit
// loss that happened before their capture began.
let lossWarningKey = "Some audio was lost during recording. The captured audio was preserved, but the recording may be incomplete."
precondition(JarasLocalization.string(lossWarningKey, language: "en") == lossWarningKey)
precondition(JarasLocalization.string(lossWarningKey, language: "pt-BR") == "Parte do áudio foi perdida durante a gravação. O áudio capturado foi preservado, mas a gravação pode estar incompleta.",
             "recording loss warning follows the selected application language")
let lossRing = JarasCaptureRing(channels: 4, capacity: 100)
lossRing.push(buffer)
precondition(lossRing.droppedFrames == 47900, "fixture starts with a previously used ring")
let lossTrack = CaptureTarget(track: UUID(), input: .stereo, format: "wav32", name: "Overflow - 001")
let cleanTrack = CaptureTarget(track: UUID(), input: .stereo, format: "wav32", name: "Overflow - 002")
let lossWriter = try CaptureWriter(targets: [lossTrack], directory: directory, format: format, ring: lossRing)
lossWriter.start()
precondition(lossRing.droppedFrames == 0, "beginCapture clears loss from a prior session")
lossRing.push(buffer)
precondition(lossRing.droppedFrames == 47900, "one oversized capture block deterministically overflows the tiny ring")
let lossDone = DispatchSemaphore(value: 0)
lossWriter.changeTargets([cleanTrack], position: 10) { items, message in
    precondition(items.count == 1 && items[0].track == lossTrack.track, "overflow preserves the partially recorded item")
    precondition(message == JarasLocalization.string(lossWarningKey), "a partial take explicitly reports the lost audio")
    let file = try! AVAudioFile(forReading: directory.appendingPathComponent(items[0].clip.audioFile!.path))
    precondition(file.length == 100 && items[0].clip.duration == 100.0 / 48000,
                 "overflow does not invent missing samples or delete accepted frames")
    let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 100)!
    try! file.read(into: pcm)
    for channel in 0..<2 { for frame in 0..<100 {
        precondition(abs(pcm.floatChannelData![channel][frame] - buffer.floatChannelData![channel][frame]) < 0.000001,
                     "overflow leaves captured PCM intact")
    } }
    lossDone.signal()
}
precondition(lossDone.wait(timeout: .now() + 5) == .success, "partial take warning completes while another track stays armed")
let cleanBlock = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64)!
cleanBlock.frameLength = 64
for channel in 0..<4 { for frame in 0..<64 { cleanBlock.floatChannelData![channel][frame] = buffer.floatChannelData![channel][frame] } }
lossRing.push(cleanBlock)
let cleanDone = DispatchSemaphore(value: 0)
lossWriter.finish(start: 10) { items, message in
    precondition(items.count == 1 && items[0].track == cleanTrack.track && message == nil,
                 "a track armed after the overflow does not inherit an earlier take's warning")
    precondition(items[0].clip.duration == 64.0 / 48000, "the later track only receives its own captured frames")
    cleanDone.signal()
}
precondition(cleanDone.wait(timeout: .now() + 5) == .success)
let cleanSession = try CaptureWriter(targets: [CaptureTarget(track: UUID(), input: .stereo, format: "wav32", name: "Overflow - 003")],
                                     directory: directory, format: format, ring: lossRing)
cleanSession.start(); lossRing.push(cleanBlock)
let cleanSessionDone = DispatchSemaphore(value: 0)
cleanSession.finish(start: 20) { items, message in
    precondition(items.count == 1 && message == nil && lossRing.droppedFrames == 0,
                 "a new recording reusing the ring starts without a stale loss warning")
    cleanSessionDone.signal()
}
precondition(cleanSessionDone.wait(timeout: .now() + 5) == .success)
print("RECORDING_OVERFLOW_LOCALIZED_PARTIAL_TAKE_WARNING_PRESERVED_PCM_NEW_TARGET_AND_REUSED_SESSION_OK")

// Independent arming while global REC stays active, including zero targets.
let dynamic = try CaptureWriter(targets: [], directory: directory, format: format)
let a = CaptureTarget(track: UUID(), input: .stereo, format: "wav", name: "Capture - 007", lane: 4)
let b = CaptureTarget(track: UUID(), input: .stereo, format: "wav", name: "Capture - 008", lane: 2)
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
    let target = CaptureTarget(track: UUID(), input: .stereo, format: formatKey, name: formatKey)
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
    CaptureTarget(track: UUID(), input: OutputPatch(firstChannel: 3, channelCount: 2), format: "wav", name: "Capture - 009", recordedChannels: 1),
    CaptureTarget(track: UUID(), input: OutputPatch(firstChannel: 2, channelCount: 1), format: "wav", name: "Capture - 010", recordedChannels: 2)
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

var names = RecordingNames(directory: directory, clips: [AudioClip(id: UUID(), name: "Piano - 001", startTime: 0, duration: 1)])
precondition(names.allocate(track: "Piano") == "Piano")
precondition(names.allocate(track: "Piano") == "Piano - 002")
precondition(names.allocate(track: "Piano") == "Piano - 003")
precondition(names.allocate(track: "PIANO") == "PIANO - 004")
print("RECORDING_NAMES_OK")

let monitorEngine = AVAudioEngine()
let monitorFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
try monitorEngine.enableManualRenderingMode(.offline, format: monitorFormat, maximumFrameCount: 512)
let monitorRing = JarasCaptureRing(channels: 4, capacity: 4096)
let monitorSource = monitorRing.monitorSource(withSampleRate: 48000, firstChannel: 2, channelCount: 2)
monitorEngine.attach(monitorSource); monitorEngine.connect(monitorSource, to: monitorEngine.mainMixerNode, format: monitorFormat)
try monitorEngine.start()
let small = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
small.frameLength = 1024
for c in 0..<4 { small.floatChannelData![c].update(repeating: Float(c + 1) / 10, count: 1024) }
monitorRing.endCapture()
monitorRing.push(small)
precondition(abs(monitorRing.takeInputPeak(2)-0.3)<0.0001 && abs(monitorRing.takeInputPeak(3)-0.4)<0.0001,
    "Armed input meters must read selected channels with recording stopped")
precondition(monitorRing.takeInputPeak(2)==0, "Input peak consumption must clear held callback values")
monitorRing.beginCapture()
monitorRing.push(small)
let monitorPCM = AVAudioPCMBuffer(pcmFormat: monitorFormat, frameCapacity: 512)!
let monitorStatus = try monitorEngine.renderOffline(512, to: monitorPCM); precondition(monitorStatus == .success)
precondition(abs(monitorPCM.floatChannelData![0][100] - 0.3) < 0.0001 && abs(monitorPCM.floatChannelData![1][100] - 0.4) < 0.0001, "live monitor maps input channels 3/4 independently from the recording writer")
monitorEngine.stop()
print("INPUT_MONITOR_NATIVE_RING_CHANNEL_MAPPING_OK")

// Inspect actual MPEG frame headers; a renamed WAV does not pass this check.
let bitrateIndices = [128: 9, 160: 10, 192: 11, 224: 12, 256: 13, 320: 14]
for rate in [128, 160, 192, 224, 256, 320] {
    let writer = try CaptureWriter(targets: [CaptureTarget(track: UUID(), input: .stereo, format: "mp3-\(rate)", name: "Bitrate - \(rate)")], directory: directory, format: format)
    let finished = DispatchSemaphore(value: 0)
    writer.start(); writer.ring.push(buffer)
    writer.finish(start: 0) { items, error in
        precondition(error == nil && items.count == 1)
        let url = directory.appendingPathComponent(items[0].clip.audioFile!.path)
        precondition(url.pathExtension == "mp3")
        let bytes = [UInt8](try! Data(contentsOf: url))
        let header = (0..<min(bytes.count - 4, 4096)).first {
            bytes[$0] == 0xff && bytes[$0 + 1] & 0xfe == 0xfa && Int(bytes[$0 + 2] >> 4) == bitrateIndices[rate]
        }
        precondition(header != nil, "MP3 frame header must match the chosen \(rate) kbps")
        let file = try! AVAudioFile(forReading: url)
        precondition(file.length > 0 && file.processingFormat.channelCount == 2)
        finished.signal()
    }
    precondition(finished.wait(timeout: .now() + 10) == .success)
}
print("RECORDING_MP3_128_160_192_224_256_320_REAL_CODEC_OK")

let multitrackFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 32)!)
let multitrackPCM = AVAudioPCMBuffer(pcmFormat: multitrackFormat, frameCapacity: 4096)!
multitrackPCM.frameLength = 4096
for channel in 0..<32 { multitrackPCM.floatChannelData![channel].update(repeating: Float(channel + 1) / 100, count: 4096) }
let multitrackTargets = (1...32).map { CaptureTarget(track: UUID(), input: OutputPatch(firstChannel: $0, channelCount: 1), format: "wav24pcm", name: String(format: "REC - %02d", $0), recordedChannels: 1) }
let multitrackWriter = try CaptureWriter(targets: multitrackTargets, directory: directory, format: multitrackFormat)
let multitrackFinished = DispatchSemaphore(value: 0)
multitrackWriter.start(); multitrackWriter.ring.push(multitrackPCM)
multitrackWriter.finish(start: 0) { items, error in
    precondition(error == nil && items.count == 32, "Every armed mono input creates its own take")
    for (index, item) in items.enumerated() {
        precondition(item.track == multitrackTargets[index].track)
        let file = try! AVAudioFile(forReading: directory.appendingPathComponent(item.clip.audioFile!.path))
        precondition(file.length == 4096 && file.processingFormat.channelCount == 1)
        precondition(file.fileFormat.streamDescription.pointee.mBitsPerChannel == 24)
        let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 100)!
        try! file.read(into: pcm)
        precondition(abs(pcm.floatChannelData![0][20] - Float(index + 1) / 100) < 0.000001, "Input routing must remain independent across all 32 tracks")
    }
    multitrackFinished.signal()
}
precondition(multitrackFinished.wait(timeout: .now() + 10) == .success)
print("RECORDING_32_MONO_FILES_SEQUENTIAL_INPUT_PCM_OK")

// All four stages use ONLY the selected new input, with identical live/file PCM.
for postFader in [false, true] { for postFX in [false, true] {
    var fx = NativeFXSettings(); fx.inserted = ["Compressor"]
    fx.compressorEnabled = true; fx.ratio = 1; fx.makeup = 6
    let name = "Stages-\(postFader)-\(postFX)"
    let target = CaptureTarget(track: UUID(), input: OutputPatch(firstChannel: 3, channelCount: 2), format: "wav32", name: name,
                               postFader: postFader, postFX: postFX, gain: 0.25, effects: fx)
    let recorder = try CaptureWriter(targets: [target], directory: directory, format: format)
    let done = DispatchSemaphore(value: 0)
    recorder.start(); recorder.ring.push(buffer)
    recorder.finish(start: 0) { items, error in
        precondition(error == nil && items.count == 1, "stage capture failed: \(error ?? "missing take")")
        let file = try! AVAudioFile(forReading: directory.appendingPathComponent(items[0].clip.audioFile!.path))
        precondition(file.length == 48000, "FX latency changed recording length")
        let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48000)!
        try! file.read(into: pcm)
        let expected = Float(0.3 * (postFader ? 0.25 : 1) * (postFX ? pow(10, 6.0/20) : 1))
        let peak = (10000..<40000).map { abs(pcm.floatChannelData![0][$0]) }.max()!
        precondition(abs(peak - expected) < 0.002, "pre/post recording stage mismatch: \(name) \(peak) expected \(expected)")
        done.signal()
    }
    precondition(done.wait(timeout: .now() + 15) == .success, "stage writer stalled")
} }
print("RECORDING_INPUT_ONLY_PRE_POST_FADER_FX_OK")

let fixturePath = ProcessInfo.processInfo.environment["JARAS_TEST_VST3"]!
_ = NSApplication.shared
for latency in [0, 777, 4096] {
    setenv("CATLIVE_TEST_VST3_LATENCY_FRAMES", String(latency), 1)
    var plugin = ExternalPlugin(classID: "1234123456785678ABCDEF0012345678", name: "Recording latency fixture", path: fixturePath)
    var unity: Float = 1
    plugin.componentState = withUnsafeBytes(of: &unity) { Data($0).base64EncodedString() }
    var fx = NativeFXSettings(); fx.externalPlugins = [plugin]; fx.inserted = [plugin.effectKey]
    let target = CaptureTarget(track: UUID(), input: .stereo, format: "wav32", name: "Latency-\(latency)", effects: fx)
    let recorder = try CaptureWriter(targets: [target], directory: directory, format: format)
    let done = DispatchSemaphore(value: 0)
    recorder.start(); recorder.ring.push(buffer)
    recorder.finish(start: 17) { items, error in
        precondition(error == nil && items.count == 1, "VST3 input capture failed: \(error ?? "missing take")")
        let file = try! AVAudioFile(forReading: directory.appendingPathComponent(items[0].clip.audioFile!.path))
        precondition(file.length == 48000 && items[0].clip.startTime == 17, "VST3 changed captured bounds")
        let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48000)!
        try! file.read(into: pcm)
        for channel in 0..<2 {
            let difference = (0..<48000).map { abs(pcm.floatChannelData![channel][$0] - buffer.floatChannelData![channel][$0]) }.max()!
            precondition(difference < 0.00001, "VST3 recording shifted or lost PCM: latency=\(latency), error=\(difference)")
        }
        done.signal()
    }
    precondition(done.wait(timeout: .now() + 20) == .success, "VST3 writer stalled")
}
unsetenv("CATLIVE_TEST_VST3_LATENCY_FRAMES")
print("RECORDING_VST3_LATENCY_COMPENSATED_OK")
var stageTrack = Track(id: UUID(), name: "Stages", role: .other)
precondition(stageTrack.recordingPostFX != false && stageTrack.recordingPostFader != false)
stageTrack.recordingPostFX = false; stageTrack.recordingPostFader = true
let stageRoundtrip = try JSONDecoder().decode(Track.self, from: JSONEncoder().encode(stageTrack))
precondition(stageRoundtrip.recordingPostFX == false && stageRoundtrip.recordingPostFader == true)
print("RECORDING_STAGE_DEFAULTS_AND_PERSISTENCE_OK")
