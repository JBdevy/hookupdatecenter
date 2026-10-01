import Foundation
import AVFoundation
import Darwin
setbuf(stdout, nil)
final class IdleOnsetCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Double?
    func reset() { lock.lock(); first = nil; lock.unlock() }
    func received(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let samples = buffer.floatChannelData?[0],
              let sample = (0..<Int(buffer.frameLength)).first(where: { abs(samples[$0]) > 0.001 }) else { return }
        lock.lock(); defer { lock.unlock() }
        if first == nil { first = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) + Double(sample) / buffer.format.sampleRate : ProcessInfo.processInfo.systemUptime }
    }
    var onset: Double? { lock.lock(); defer { lock.unlock() }; return first }
}
@MainActor func runWarmTransportTest() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let frames = Int(rate * 10)
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for c in 0..<2 { for i in 0..<frames { buffer.floatChannelData![c][i] = 0.01 } }
    let url = directory.appendingPathComponent("tone.wav")
    do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
    let engine = AVAudioEngine()
    let audio = StemAudioPlayback(engine: engine, realtime: true)
    audio.open(directory: directory)
    defer { audio.prepareForClosing() }
    var project = Project.empty(name: "Warm transport test")
    project.masterMute = true // Exercise the live graph without audible output.
    project.songs[0].tracks = (0..<24).map { index in
        var track = Track(id: UUID(), name: "Track \(index)", role: .keys)
        track.clips = [AudioClip(id: UUID(), name: "Tone", startTime: 0, duration: 10, audioFile: AudioFile(path: "tone.wav"))]
        return track
    }
    var snapshot = ShowSnapshot(project: project, transport: TransportState(playing: false, songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    try audio.update(snapshot, revision: 1)
    let buses = Mirror(reflecting: audio).children.first { $0.label == "trackBuses" }!.value
    let captures = Mirror(reflecting: buses).children.map { entry -> (AVAudioMixerNode, IdleOnsetCapture) in
        let bus = Array(Mirror(reflecting: entry.value).children)[1].value
        let mix = Mirror(reflecting: bus).children.first { $0.label == "mix" }!.value as! AVAudioMixerNode
        let capture = IdleOnsetCapture()
        mix.installTap(onBus: 0, bufferSize: 512, format: nil) { buffer, time in capture.received(buffer, time: time) }
        return (mix, capture)
    }
    defer { for (mix, _) in captures { mix.removeTap(onBus: 0) } }
    for attempt in 0..<3 {
        let idleSeconds = Double(ProcessInfo.processInfo.environment["JARAS_TEST_IDLE_SECONDS"] ?? "3")!
        try await Task.sleep(nanoseconds: UInt64(idleSeconds * 1_000_000_000))
        precondition(engine.isRunning, "Audio device must stay running while stopped")
        for (_, capture) in captures { capture.reset() }
        snapshot.transport.playing = true
        let start = ProcessInfo.processInfo.systemUptime
        try audio.update(snapshot, revision: 1)
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        precondition(elapsed < 150, "24 warmed tracks must not wait one I/O cycle per track: \(elapsed) ms")
        print("REALTIME_WARM_TRANSPORT_OK attempt=\(attempt) playCommandMs=\(elapsed)")
        for _ in 0..<100 {
            if captures.allSatisfy({ $0.1.onset != nil }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let delays = captures.compactMap { $0.1.onset.map { ($0 - start) * 1000 } }
        print("REALTIME_IDLE_ONSET attempt=\(attempt) voices=\(delays.count) maxMs=\(delays.max() ?? -1)")
        precondition(delays.count == 24 && (delays.max() ?? 1000) < 300,
                     "Every track must produce PCM promptly after idle, not just return from Play")
        snapshot.transport.playing = false
        snapshot.transport.position = 0
        try audio.update(snapshot, revision: 1)
    }
}
Task { @MainActor in
    do { try await runWarmTransportTest(); exit(0) }
    catch { print("REALTIME_WARM_TRANSPORT_FAILED \(error)"); exit(1) }
}
dispatchMain()
