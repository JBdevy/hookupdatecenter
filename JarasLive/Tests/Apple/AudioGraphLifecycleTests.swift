import Foundation
import AVFoundation
import Darwin

setbuf(stdout, nil)

@MainActor func runAudioGraphLifecycleTests() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
    pcm.frameLength = pcm.frameCapacity
    for channel in 0..<2 {
        pcm.floatChannelData![channel].update(repeating: 0.1, count: Int(pcm.frameLength))
    }
    func writeSource(_ name: String) throws {
        let file = try AVAudioFile(forWriting: directory.appendingPathComponent(name), settings: format.settings)
        try file.write(from: pcm)
    }
    try writeSource("first.wav"); try writeSource("second.wav")
    var project = Project.empty(name: "Audio graph lifecycle")
    var track = Track(id: UUID(), name: "Media", role: .other)
    let first = AudioClip(id: UUID(), name: "First", startTime: 0, duration: 1, audioFile: AudioFile(path: "first.wav"))
    let second = AudioClip(id: UUID(), name: "Second", startTime: 4, duration: 1, audioFile: AudioFile(path: "second.wav"))
    track.clips = [first, second]; project.songs[0].tracks = [track]
    let snapshot = ShowSnapshot(project: project, transport: TransportState(playing: false,
        songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false),
        subPlay: SubPlayState(playing: false, position: 0)))
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let audio = StemAudioPlayback(engine: engine, realtime: true)
    defer { audio.prepareForClosing() }
    var errors: [Error] = []
    audio.onError = { errors.append($0) }
    func players() -> [AVAudioPlayerNode] { engine.attachedNodes.compactMap { $0 as? AVAudioPlayerNode } }
    audio.open(directory: directory)
    try audio.update(snapshot, revision: 1)
    try await Task.sleep(nanoseconds: 100_000_000)
    precondition(players().count == 1 && players().allSatisfy { !$0.isPlaying })
    precondition(audio.effects(for: second.id) != nil, "the second item reuses the prepared source")
    let preparedCount = engine.attachedNodes.count
    precondition(players().count == 1)
    try FileManager.default.removeItem(at: directory.appendingPathComponent("first.wav"))
    precondition(audio.effects(for: first.id) == nil && errors.count == 1,
        "a missing cached source must report an error without abandoning the prepared graph")
    try writeSource("first.wav")
    precondition(audio.effects(for: first.id) != nil)
    precondition(players().count == 1 && engine.attachedNodes.count == preparedCount,
        "recovering unavailable media must reuse its retained voice, not leak the old nodes")
    audio.prepareForClosing()
    precondition(players().isEmpty, "closing must release every player, including failed preparations")
    print("AUDIO_MISSING_CACHED_MEDIA_PRESERVES_POOLED_GRAPH_AND_CLOSE_RELEASES_IT_OK rate=\(rate)")

    // The former idle task called play after a close/project change. Queue many
    // preparations and interleave cancellation before and after task suspension.
    var many = snapshot
    many.project.songs[0].tracks = (0..<12).map { index in
        var copy = track; copy.id = UUID(); copy.name = "Pending \(index)"
        copy.clips = [first]; copy.clips[0].id = UUID(); return copy
    }
    for iteration in 0..<12 {
        audio.open(directory: directory)
        try audio.update(many, revision: UInt64(iteration + 2))
        if iteration % 2 == 1 { await Task.yield() }
        audio.prepareForClosing()
        for _ in 0..<3 { await Task.yield() }
        precondition(!engine.isRunning && players().isEmpty,
            "cancelled preparation must neither restart the engine nor attach a player after closing")
    }
    audio.open(directory: directory)
    try audio.update(snapshot, revision: 20)
    try await Task.sleep(nanoseconds: 100_000_000)
    precondition(players().count == 1 && players().allSatisfy { !$0.isPlaying })
    audio.prepareForClosing()
    try await Task.sleep(nanoseconds: 50_000_000)
    precondition(!engine.isRunning && players().isEmpty && errors.count == 1)
    print("AUDIO_PENDING_PREPARATION_CLOSE_REOPEN_CANCELLATION_OK rate=\(rate)")
}

Task { @MainActor in
    do { try await runAudioGraphLifecycleTests(); exit(0) }
    catch { print("AUDIO_GRAPH_LIFECYCLE_ERROR", error); exit(1) }
}
dispatchMain()
