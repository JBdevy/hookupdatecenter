import Foundation
import AVFoundation
import Darwin

setbuf(stdout, nil)
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-offline-latency-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer {
    unsetenv("CATLIVE_TEST_VST3_LATENCY_FRAMES")
    try? FileManager.default.removeItem(at: directory)
}
guard let path = ProcessInfo.processInfo.environment["JARAS_TEST_VST3"] else {
    fatalError("Build GainFixture.vst3 and set JARAS_TEST_VST3 before this regression test")
}
var scanError: NSError?
let scanned = JarasVST3.scan(path, error: &scanError)
precondition(scanError == nil && scanned.count == 1)
var plugin = ExternalPlugin(classID: scanned[0]["classID"] as! String, name: "Latency fixture", path: path)
var unity: Float = 1
plugin.componentState = withUnsafeBytes(of: &unity) { Data($0).base64EncodedString() }
var effects = NativeFXSettings()
effects.externalPlugins = [plugin]; effects.inserted = [plugin.effectKey]

func read(_ url: URL) throws -> [[Float]] {
    let file = try AVAudioFile(forReading: url)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return (0..<Int(buffer.format.channelCount)).map {
        Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: Int(buffer.frameLength)))
    }
}
var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("FAIL \(message)") }
}
for sampleRate in [44100.0, 48000.0] {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let frames = 12000
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    pcm.frameLength = AVAudioFrameCount(frames)
    var expected = [[Float]](repeating: [Float](repeating: 0, count: frames), count: 2)
    // Attacks at the selected beginning, several middle positions, and the
    // final sample expose common shifts, lane skew, and a cut delayed tail.
    for channel in 0..<2 {
        for frame in 0..<frames {
            let pulse: Float = frame < 16 ? 0.2 : (6000..<6016).contains(frame) ? -0.15 : frame >= frames - 16 ? 0.25 : 0
            expected[channel][frame] = channel == 0 ? pulse : -pulse * 0.75
            pcm.floatChannelData![channel][frame] = expected[channel][frame]
        }
    }
    let sourceName = "source-\(Int(sampleRate)).wav"
    do {
        let source = try AVAudioFile(forWriting: directory.appendingPathComponent(sourceName), settings: format.settings)
        try source.write(from: pcm)
    }
    for (delay, masterDelay) in [(0, false), (1024, false), (777, true)] {
        setenv("CATLIVE_TEST_VST3_LATENCY_FRAMES", String(delay), 1)
        let origin = Double(8192) / sampleRate, duration = Double(frames) / sampleRate
        var project = Project.empty(name: "Offline PDC")
        var dry = Track(id: UUID(), name: "Dry", role: .other)
        var wet = Track(id: UUID(), name: "Delayed", role: .other)
        dry.outputs = [.master]; wet.outputs = [.master]
        dry.volume = 0.5; wet.fx = effects
        dry.clips = [AudioClip(id: UUID(), name: sourceName, startTime: origin, duration: duration, audioFile: AudioFile(path: sourceName))]
        wet.clips = [AudioClip(id: UUID(), name: sourceName, startTime: origin, duration: duration, audioFile: AudioFile(path: sourceName))]
        project.songs[0].tracks = [dry, wet]
        project.songs[0].duration = origin + duration
        if masterDelay { project.masterFX = effects }
        let jobs = [
            AudioExportJob(id: "master", fileName: "master.wav", start: origin, end: origin + duration),
            AudioExportJob(id: "dry", fileName: "dry.wav", start: origin, end: origin + duration, track: dry.id),
            AudioExportJob(id: "wet", fileName: "wet.wav", start: origin, end: origin + duration, track: wet.id)
        ]
        let output = directory.appendingPathComponent("\(Int(sampleRate))-\(delay)-\(masterDelay)")
        try OfflineAudioExport.run(project: project, song: project.songs[0], plan: AudioExportPlan(jobs: jobs),
            mediaDirectory: directory, outputDirectory: output, sampleRate: sampleRate,
            encoding: AudioExportEncoding(bitDepth: 32), cancellation: AudioExportCancellation()) { _ in }
        let rendered = try jobs.map { try read(output.appendingPathComponent($0.fileName)) }
        let tag = "rate=\(Int(sampleRate)) latency=\(delay) masterLatency=\(masterDelay ? delay : 0)"
        for index in jobs.indices {
            let scale: Float = index == 0 ? 1.5 : index == 1 ? 0.5 : 1
            for channel in 0..<2 {
                let actual = rendered[index][channel]
                check(actual.count == frames, "exact selected duration \(jobs[index].id) \(tag)")
                let first = actual.firstIndex { abs($0) > 0.00001 } ?? -1
                let last = actual.lastIndex { abs($0) > 0.00001 } ?? -1
                let error = zip(actual, expected[channel]).map { abs($0 - $1 * scale) }.max() ?? .infinity
                print("PDC \(tag) lane=\(jobs[index].id) channel=\(channel) onset=\(first) last=\(last) maxError=\(error)")
                check(first == 0, "first transient remains at selection start \(jobs[index].id) channel=\(channel) \(tag)")
                check(last == frames - 1, "delayed last transient is flushed instead of truncated \(jobs[index].id) channel=\(channel) \(tag)")
                check(error < 0.00001, "sample-accurate PCM with compensated processor latency \(jobs[index].id) channel=\(channel) \(tag)")
            }
        }
        for channel in 0..<2 {
            let error = zip(rendered[0][channel], zip(rendered[1][channel], rendered[2][channel])).map { abs($0 - $1.0 - $1.1) }.max() ?? .infinity
            check(error < 0.00001, "simultaneous Master equals dry+processed track exports channel=\(channel) \(tag)")
        }
    }
}
guard failures == 0 else { print("OFFLINE_VST3_LATENCY_FAILED assertions=\(failures)"); exit(1) }
print("OFFLINE_VST3_TRACK_AND_MASTER_LATENCY_ONSETS_TAILS_SUM_AND_DURATION_44100_48000_OK")
