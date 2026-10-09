import Foundation
import AVFoundation
import Darwin
setbuf(stdout, nil)

final class IdleStartCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var hits: [UInt64] = []
    func append(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
        guard let samples = buffer.floatChannelData else { return }
        lock.lock(); defer { lock.unlock() }
        for i in 0..<Int(buffer.frameLength) where abs(samples[0][i]) > 0.05 {
            hits.append(time.hostTime + AVAudioTime.hostTime(forSeconds: Double(i) / buffer.format.sampleRate))
            break
        }
    }
    func onset(after host: UInt64) -> Double? {
        lock.lock(); defer { lock.unlock() }
        // The stretcher's compensated output may lead the nominal boundary
        // slightly; accept the same 20 ms early window as jump-transient tests.
        return hits.map { Double(Int64(bitPattern: $0 &- host)) * AVAudioTime.seconds(forHostTime: 1) }
            .first { $0 >= -0.02 }
    }
}
@MainActor func field(_ name: String, _ value: Any) -> Any? {
    Mirror(reflecting: value).children.first { $0.label == name }?.value
}
func cpuSeconds() -> Double {
    var value = rusage(); getrusage(RUSAGE_SELF, &value)
    return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
}
@MainActor func run() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 2))!
    pcm.frameLength = pcm.frameCapacity
    for channel in 0..<2 { for i in 0..<Int(pcm.frameLength) {
        pcm.floatChannelData![channel][i] = i < Int(rate * 0.025) ? 0.5 : 0
    } }
    do {
        let file = try AVAudioFile(forWriting: directory.appendingPathComponent("attack.wav"), settings: format.settings)
        try file.write(from: pcm)
    }
    var project = Project.empty(name: "Idle preparation")
    project.songs[0].tracks = (0..<24).map { index in
        var track = Track(id: UUID(), name: "Stem \(index)", role: .other)
        track.volume = 1.0 / 24
        var clip = AudioClip(id: UUID(), name: "Attack", startTime: 0, duration: 1.8,
                             audioFile: AudioFile(path: "attack.wav"), playbackRate: 61.0 / 60)
        clip.pitchSemitones = 2
        track.clips = [clip]
        return track
    }
    let engine = AVAudioEngine(), audio = StemAudioPlayback(engine: engine, realtime: true)
    audio.open(directory: directory)
    defer { audio.prepareForClosing() }
    var state = ShowSnapshot(project: project, transport: TransportState(playing: false, songId: project.songs[0].id,
        position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    try audio.update(state, revision: 1)
    engine.mainMixerNode.outputVolume = 0
    try await Task.sleep(nanoseconds: 2_000_000_000)
    let players = engine.attachedNodes.compactMap { $0 as? AVAudioPlayerNode }
    precondition(players.count >= 24, "Prepare the players before measuring idle")
    precondition(players.allSatisfy { !$0.isPlaying }, "Idle preparation must not continuously process silent loops")
    let startCPU = cpuSeconds(), start = ProcessInfo.processInfo.systemUptime
    try await Task.sleep(nanoseconds: 2_000_000_000)
    print("IDLE_CPU", (cpuSeconds() - startCPU) / (ProcessInfo.processInfo.systemUptime - start) * 100, "RATE", rate)
    let master = field("masterBus", audio) as! AVAudioMixerNode
    let capture = IdleStartCapture()
    master.installTap(onBus: 0, bufferSize: 128, format: nil) { capture.append($0, $1) }
    defer { master.removeTap(onBus: 0) }
    state.transport.playing = true
    try audio.update(state, revision: 1)
    let clocks = field("headAudioClock", audio) as! [Int: (position: Double, host: UInt64)]
    let host = clocks[0]!.host
    try await Task.sleep(nanoseconds: 600_000_000)
    let onset = capture.onset(after: host)
    print("IDLE_FIRST_ATTACK", String(describing: onset), "RATE", rate)
    precondition(onset != nil && onset! < 0.03, "Play after idle must preserve the first transient")
    state.transport.playing = false
    try audio.update(state, revision: 1)
    try await Task.sleep(nanoseconds: 1_000_000_000)
    precondition(engine.attachedNodes.compactMap { $0 as? AVAudioPlayerNode }.allSatisfy { !$0.isPlaying },
                 "Stopping must return prepared players to idle")
    print("IDLE_PREPARATION_AND_FIRST_ATTACK_OK")
}
Task { @MainActor in do { try await run(); exit(0) } catch { print(error); exit(1) } }
dispatchMain()
