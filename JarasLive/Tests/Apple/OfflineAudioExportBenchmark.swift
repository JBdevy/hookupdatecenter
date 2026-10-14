import Foundation
import AVFoundation
import Darwin

// Synthetic PCM integration tests and an offline-export benchmark. Compile via
// test-offline-export.sh with CATLIVE_EXPORT_TEST_OPTIMIZED=1; no speed assertion
// depends on the machine. Render timing excludes fixture creation/PCM analysis.
setbuf(stdout, nil)
AudioLicenseAccess.shared.setAllowed(true)
let environment = ProcessInfo.processInfo.environment
let seconds = min(90, max(8, Double(environment["CATLIVE_EXPORT_BENCH_SECONDS"] ?? "30") ?? 30))
let trackCount = min(64, max(2, Int(environment["CATLIVE_EXPORT_BENCH_TRACKS"] ?? "16") ?? 16))
let selected = Set((environment["CATLIVE_EXPORT_BENCH_CASES"] ?? "unit,mix,rate,variable,loop,mp3,sparse").split(separator: ",").map(String.init))
let sampleRate = 48000.0
let root = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-export-benchmark-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer {
    if environment["CATLIVE_EXPORT_BENCH_KEEP"] == "1" { print("SYNTHETIC_FIXTURES_RETAINED \(root.path)") }
    else { try? FileManager.default.removeItem(at: root) }
}
var failures: [String] = []
func verify(_ value: Bool, _ message: String) {
    if !value { failures.append(message); print("PCM_FAILURE \(message)") }
}
func report(_ kind: String, _ values: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
    print("\(kind) \(String(decoding: data, as: UTF8.self))")
}
func cpuSeconds() -> Double {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}
func peakRSSMiB() -> Double { var usage = rusage(); getrusage(RUSAGE_SELF, &usage); return Double(usage.ru_maxrss) / 1_048_576 }
let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
func amplitude(_ time: Double) -> Double { [0.03, 0.09, 0.05, 0.12, 0.04, 0.075][Int(max(0, time).rounded(.down)) % 6] }
func writeSource() throws {
    let count = Int((seconds * 1.5 + 4) * sampleRate)
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
    let file = try AVAudioFile(forWriting: root.appendingPathComponent("coded.wav"), settings: format.settings)
    for start in stride(from: 0, to: count, by: 4096) {
        pcm.frameLength = AVAudioFrameCount(min(4096, count - start))
        for frame in 0..<Int(pcm.frameLength) {
            let time = Double(start + frame) / sampleRate
            for channel in 0..<2 {
                pcm.floatChannelData![channel][frame] = Float(amplitude(time) * sin(2 * .pi * Double(channel == 0 ? 240 : 360) * time))
            }
        }
        try file.write(from: pcm)
    }
}
struct PCM {
    let channels: [[Float]]
    var frames: Int { channels[0].count }
    func rms(_ range: Range<Int>, channel: Int = 0) -> Double {
        let lower = max(0, range.lowerBound), upper = min(frames, range.upperBound)
        guard upper > lower else { return 0 }
        var energy = 0.0
        for frame in lower..<upper { let x = Double(channels[channel][frame]); energy += x * x }
        return sqrt(energy / Double(upper - lower))
    }
    func rms(at time: Double, duration: Double = 0.04, channel: Int = 0) -> Double {
        let first = Int((time - duration / 2) * sampleRate)
        return rms(first..<(first + Int(duration * sampleRate)), channel: channel)
    }
}
func readPCM(_ url: URL) throws -> PCM {
    let file = try AudioFileRead.openMedia(url)
    verify(file.processingFormat.sampleRate == sampleRate && file.processingFormat.channelCount == 2, "\(url.lastPathComponent): stereo rate")
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16384)!
    var channels = [[Float](), [Float]()]
    for channel in 0..<2 { channels[channel].reserveCapacity(Int(file.length)) }
    while file.framePosition < file.length {
        try file.read(into: buffer)
        if buffer.frameLength == 0 { break }
        for channel in 0..<2 { channels[channel].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength))) }
    }
    return PCM(channels: channels)
}
try writeSource()
let source = try readPCM(root.appendingPathComponent("coded.wav"))

func projectWith(_ tracks: [Track], duration: Double) -> Project {
    var result = Project.empty(name: "Synthetic export benchmark")
    result.songs[0].tracks = tracks; result.songs[0].duration = duration
    result.songs[0].bpm = 120
    result.songs[0].timeSettings = ProjectTimeSettings()
    result.songs[0].timeSettings?.timebase = .free
    return result
}
func track(_ name: String, start: Double, duration: Double, offset: Double = 0, rate: Double = 1,
           path: String = "coded.wav", gain: Double = 1) -> Track {
    var track = Track(id: UUID(), name: name, role: .other)
    track.outputs = [.master]; track.volume = gain
    track.clips = [AudioClip(id: UUID(), name: name, startTime: start, duration: duration,
                            sourceOffset: offset, audioFile: AudioFile(path: path), playbackRate: rate)]
    return track
}
func render(_ project: Project, name: String, start: Double = 0, end: Double? = nil) throws -> URL {
    let song = project.songs[0], end = end ?? project.songs[0].duration
    let plan = AudioExportPlan(jobs: [.init(id: name, fileName: "Master.wav", start: start, end: end, track: nil, clip: nil)])
    let destination = root.appendingPathComponent(name)
    let clock = ProcessInfo.processInfo.systemUptime, cpu = cpuSeconds()
    var updates = 0
    try OfflineAudioExport.run(project: project, song: song, plan: plan, mediaDirectory: root,
        outputDirectory: destination, sampleRate: sampleRate,
        encoding: AudioExportEncoding(bitDepth: 24), cancellation: AudioExportCancellation()) { _ in updates += 1 }
    let elapsed = ProcessInfo.processInfo.systemUptime - clock
    report("EXPORT_BENCHMARK", ["case": name, "audioSeconds": end - start, "wallSeconds": elapsed,
        "cpuSeconds": cpuSeconds() - cpu, "realtimeFactor": (end - start) / elapsed,
        "tracks": song.tracks.count, "clips": song.tracks.reduce(0) { $0 + $1.clips.count },
        "markers": song.markers?.count ?? 0, "progressCallbacks": updates, "processPeakRSSMiB": peakRSSMiB(),
        "runLabel": environment["CATLIVE_EXPORT_BENCH_LABEL"] ?? "unspecified"])
    return destination.appendingPathComponent("Master.wav")
}
func compare(_ pcm: PCM, name: String, expectedFrames: Int, expected: (Int, Int) -> Float) {
    verify(pcm.frames == expectedFrames, "\(name): exact output length \(pcm.frames) != \(expectedFrames)")
    var maximum = 0.0, energy = 0.0, bad = 0
    for channel in 0..<2 {
        for frame in 0..<min(pcm.frames, expectedFrames) {
            let x = pcm.channels[channel][frame]
            if !x.isFinite { bad += 1; continue }
            let error = Double(abs(x - expected(frame, channel)))
            maximum = max(maximum, error); energy += error * error
            if error > 0.00003 { bad += 1 }
        }
    }
    report("PCM_COMPARISON", ["case": name, "maximumError": maximum, "rmsError": sqrt(energy / Double(max(1, 2 * pcm.frames))), "badSamples": bad])
    verify(bad == 0, "\(name): full PCM differs at \(bad) samples; max error \(maximum)")
}
func analyzeRate(_ pcm: PCM, name: String, start: Double, duration: Double,
                 semitones: Double = 0, seams: [Double] = [], sourceTime: (Double) -> Double) {
    verify(pcm.frames == Int(((start + duration + 0.25) * sampleRate).rounded()), "\(name): exact stretched export bounds")
    let window = 480 // 10 ms, enough to distinguish sustained dropout from zero crossings.
    var first: Int?, last: Int?, minimumRMS = Double.greatestFiniteMagnitude, badWindows = 0
    for frame in stride(from: 0, to: max(0, pcm.frames - window), by: window) {
        let energy = pcm.rms(frame..<(frame + window))
        if energy > 0.005 { if first == nil { first = frame }; last = frame + window }
        let time = Double(frame) / sampleRate
        if time > start + 0.12 && time + 0.01 < start + duration - 0.12 {
            minimumRMS = min(minimumRMS, energy)
            if energy < 0.007 { badWindows += 1 }
        }
    }
    let onsetError = Double(first ?? -48000) / sampleRate - start
    let endError = Double(last ?? -48000) / sampleRate - start - duration
    var maxSeamStep = 0.0, seamMinimum = Double.greatestFiniteMagnitude
    for seam in seams {
        let center = Int(seam * sampleRate)
        for frame in max(1, center - 2400)..<min(pcm.frames, center + 2400) {
            maxSeamStep = max(maxSeamStep, Double(abs(pcm.channels[0][frame] - pcm.channels[0][frame - 1])))
        }
        for offset in stride(from: -2400, through: 1920, by: 480) {
            seamMinimum = min(seamMinimum, pcm.rms((center + offset)..<(center + offset + 480)))
        }
    }
    var worstAmplitudeRelativeError = 0.0, measurements = 0, worstPitchHzError = 0.0
    for time in stride(from: start + 0.5, to: start + duration - 0.5, by: 0.25) {
        let phase = sourceTime(time - start)
        let fractional = phase - floor(phase)
        if fractional < 0.18 || fractional > 0.82 || seams.contains(where: { abs($0 - time) < 0.2 }) { continue }
        let expected = amplitude(phase) / sqrt(2)
        worstAmplitudeRelativeError = max(worstAmplitudeRelativeError, abs(pcm.rms(at: time) - expected) / expected)
        measurements += 1
        let lower = Int((time - 0.1) * sampleRate), upper = lower + 9600
        for channel in 0..<2 {
            var crossings = 0
            for frame in (lower + 1)..<min(pcm.frames, upper) {
                if pcm.channels[channel][frame - 1] <= 0 && pcm.channels[channel][frame] > 0 { crossings += 1 }
            }
            let expectedHz = Double(channel == 0 ? 240 : 360) * pow(2, semitones / 12)
            worstPitchHzError = max(worstPitchHzError, abs(Double(crossings) / 0.2 - expectedHz))
        }
    }
    report("PCM_RATE_ANALYSIS", ["case": name, "onsetErrorSeconds": onsetError, "endErrorSeconds": endError,
        "bodyMinimum10msRMS": minimumRMS, "dropoutWindows": badWindows, "maximumSeamStep": maxSeamStep,
        "minimumSeam10msRMS": seams.isEmpty ? 0 : seamMinimum,
        "worstAmplitudeRelativeError": worstAmplitudeRelativeError, "amplitudeWindows": measurements, "worstPitchHzError": worstPitchHzError])
    verify(abs(onsetError) <= 0.07 && abs(endError) <= 0.07, "\(name): onset/end shifted beyond 70 ms")
    verify(badWindows == 0, "\(name): \(badWindows) sustained 10 ms audio dropouts")
    verify(maxSeamStep < 0.055, "\(name): discontinuous waveform around seams")
    verify(worstAmplitudeRelativeError < 0.30, "\(name): source-time amplitude code diverges (drift/repeat)")
    verify(worstPitchHzError <= 15, "\(name): pitch was not preserved")
}

if selected.contains("unit") {
    let onset = 0.25, offset = 0.125
    let project = projectWith([track("Unit", start: onset, duration: seconds, offset: offset)], duration: onset + seconds + 0.25)
    let pcm = try readPCM(render(project, name: "wav-unit-entire-source"))
    compare(pcm, name: "wav-unit-entire-source", expectedFrames: Int(project.songs[0].duration * sampleRate)) { frame, channel in
        let local = frame - Int(onset * sampleRate)
        return local >= 0 && local < Int(seconds * sampleRate) ? source.channels[channel][local + Int(offset * sampleRate)] : 0
    }
}
if selected.contains("mix") {
    let starts = (0..<trackCount).map { Int(Double($0) * 0.013 * sampleRate) }
    let tracks = starts.enumerated().map { index, frame in
        track("Track \(index)", start: Double(frame) / sampleRate, duration: seconds - Double(frame) / sampleRate,
              offset: Double(frame) / sampleRate, gain: 1 / Double(trackCount))
    }
    let project = projectWith(tracks, duration: seconds + 0.25)
    let pcm = try readPCM(render(project, name: "wav-\(trackCount)-tracks"))
    compare(pcm, name: "wav-\(trackCount)-tracks", expectedFrames: Int(project.songs[0].duration * sampleRate)) { frame, channel in
        guard frame < Int(seconds * sampleRate) else { return 0 }
        let active = starts.reduce(0) { $0 + (frame >= $1 ? 1 : 0) }
        return source.channels[channel][frame] * Float(active) / Float(trackCount)
    }
}
if selected.contains("rate") {
    for (rate, semitones) in [(0.6, 0.0), (1.4, 0.0), (0.75, 12.0)] {
        var channel = track("Rate", start: 0.25, duration: seconds, rate: rate)
        channel.clips[0].pitchSemitones = semitones
        let name = "wav-rate-\(rate)-pitch-\(Int(semitones))"
        let pcm = try readPCM(render(projectWith([channel], duration: seconds + 0.5), name: name))
        analyzeRate(pcm, name: name, start: 0.25, duration: seconds, semitones: semitones) { $0 * rate }
    }
}
if selected.contains("variable") {
    let onset = 0.25, rates = [1.0, 1.5, 0.75, 1.25]
    let channel = track("Variable", start: onset, duration: seconds)
    var project = projectWith([channel], duration: seconds + 0.5)
    project.songs[0].timeSettings?.timebase = .relative
    let positions = Array(stride(from: 0.0, to: seconds, by: 2))
    project.songs[0].markers = positions.enumerated().map { index, time in
        TimelineMarker(id: UUID(), name: "Tempo", position: onset + time, color: 0,
            tempoBPM: 120 * rates[index % rates.count], tempoTimebase: .relative, tempoReferenceBPM: 120)
    }
    let pcm = try readPCM(render(project, name: "wav-variable-tempo"))
    analyzeRate(pcm, name: "wav-variable-tempo", start: onset, duration: seconds, seams: positions.dropFirst().map { onset + $0 }) { time in
        var sourceTime = 0.0
        for (index, begin) in positions.enumerated() {
            sourceTime += max(0, min(2, time - begin)) * rates[index % rates.count]
        }
        return sourceTime
    }
}
if selected.contains("loop") {
    var channel = track("Loop", start: 0.25, duration: seconds)
    channel.clips[0].loopStart = 0; channel.clips[0].loopLength = 1
    let pcm = try readPCM(render(projectWith([channel], duration: seconds + 0.5), name: "wav-loop-seams"))
    compare(pcm, name: "wav-loop-seams", expectedFrames: Int((seconds + 0.5) * sampleRate)) { frame, channel in
        let local = frame - 12000
        return local >= 0 && local < Int(seconds * sampleRate) ? source.channels[channel][local % 48000] : 0
    }
}
if selected.contains("mp3") || selected.contains("sparse") {
    let file = try AVAudioFile(forReading: root.appendingPathComponent("coded.wav"))
    let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
    let encoder = try JarasMP3StreamEncoder(url: root.appendingPathComponent("coded.mp3"), sampleRate: 48000, channels: 2, bitRate: 320)
    while file.framePosition < file.length { try file.read(into: pcm); if pcm.frameLength == 0 { break }; try encoder.write(pcm) }
    try encoder.finish()
}
if selected.contains("mp3") {
    let decoded = try readPCM(root.appendingPathComponent("coded.mp3"))
    let channel = track("MP3", start: 0.25, duration: seconds, path: "coded.mp3")
    let pcm = try readPCM(render(projectWith([channel], duration: seconds + 0.5), name: "mp3-unit-decoded-reference"))
    compare(pcm, name: "mp3-unit-decoded-reference", expectedFrames: Int((seconds + 0.5) * sampleRate)) { frame, channel in
        let local = frame - 12000
        return local >= 0 && local < Int(seconds * sampleRate) ? decoded.channels[channel][local] : 0
    }
    for rate in [25.0 / 24, 29.0 / 30] {
        let channel = track("MP3 rate", start: 0.25, duration: seconds, rate: rate, path: "coded.mp3")
        let name = "mp3-rate-\(rate)"
        let pcm = try readPCM(render(projectWith([channel], duration: seconds + 0.5), name: name))
        analyzeRate(pcm, name: name, start: 0.25, duration: seconds) { $0 * rate }
    }
}
if selected.contains("sparse") {
    // Same 600 item project, once whole and once cropped to a single item per
    // track. This isolates cost of creating dormant voices/file decoders.
    let count = 20, events = 30, step = 3.0, activeDuration = 2.0
    let tracks = (0..<count).map { index -> Track in
        var channel = track("Sparse \(index)", start: 0, duration: activeDuration, path: "coded.mp3", gain: 1 / Double(count))
        channel.clips = (0..<events).map { event in
            AudioClip(id: UUID(), name: "Event \(event)", startTime: Double(event) * step, duration: activeDuration,
                      audioFile: AudioFile(path: "coded.mp3"))
        }
        return channel
    }
    let project = projectWith(tracks, duration: Double(events) * step)
    let whole = try readPCM(render(project, name: "mp3-sparse-600-whole"))
    let decoded = try readPCM(root.appendingPathComponent("coded.mp3"))
    compare(whole, name: "mp3-sparse-600-whole", expectedFrames: 90 * 48000) { frame, channel in
        let local = frame % (3 * 48000)
        return local < 2 * 48000 ? decoded.channels[channel][local] : 0
    }
    let crop = try readPCM(render(project, name: "mp3-sparse-600-crop", start: 45, end: 48))
    compare(crop, name: "mp3-sparse-600-crop", expectedFrames: 3 * 48000) { frame, channel in whole.channels[channel][45 * 48000 + frame] }
}
report("EXPORT_BENCHMARK_SUMMARY", ["failures": failures, "duration": seconds, "tracks": trackCount, "cases": selected.sorted()])
if !failures.isEmpty { exit(1) }
