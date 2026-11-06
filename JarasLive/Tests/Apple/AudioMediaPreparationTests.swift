import Foundation
import AVFoundation
import Darwin

// JARAS_AUDIO_TEST_SOURCE=Tests/Apple/AudioMediaPreparationTests.swift
// bash scripts/test-audio.sh
// Deliberate worker stalls verify cancellation without blocking MainActor.
setbuf(stdout, nil)
UserDefaults.standard.setVolatileDomain(["jaras.metronome.enabled": false], forName: UserDefaults.argumentDomain)

private final class PreparationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]
    @discardableResult func add(_ key: String, _ amount: Int = 1) -> Int {
        lock.lock(); defer { lock.unlock() }
        values[key, default: 0] += amount
        return values[key]!
    }
    func count(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return values[key, default: 0] }
}

@MainActor private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
    precondition(condition(), "Preparation condition timed out")
}

@MainActor private func run() async throws {
    let probe = PreparationProbe(), gate = DispatchSemaphore(value: 0)
    let running = Task {
        try await AudioFileRead.prepare { cancelled in
            precondition(!Thread.isMainThread, "Cold media decoding must leave MainActor responsive")
            probe.add("started")
            precondition(gate.wait(timeout: .now() + 5) == .success)
            probe.add("workerFinished")
            if cancelled() { throw CancellationError() }
            return 1
        }
    }
    try await waitUntil { probe.count("started") == 1 }
    let queued = Task {
        try await AudioFileRead.prepare { _ in probe.add("cancelledJobRan"); return 2 }
    }
    // Let the second job enqueue behind the stalled decoder.
    for _ in 0..<10 { await Task.yield() }
    queued.cancel()
    do { _ = try await queued.value; fatalError("Queued cancellation returned media") }
    catch { precondition(error is CancellationError) }
    running.cancel()
    do { _ = try await running.value; fatalError("Running cancellation returned media") }
    catch { precondition(error is CancellationError) }
    precondition(probe.count("workerFinished") == 0,
                 "Cancelling an idle read must not wait for the decoder to unblock")
    gate.signal()
    let next = try await AudioFileRead.prepare { _ in 3 }
    precondition(next == 3 && probe.count("cancelledJobRan") == 0)

    do {
        let _: Int = try await AudioFileRead.prepare { _ in throw NSError(domain: "Fixture", code: 7) }
        fatalError("Decoder failure was discarded")
    } catch { precondition((error as NSError).code == 7) }
    try await withThrowingTaskGroup(of: Int.self) { group in
        for _ in 0..<12 {
            group.addTask {
                try await AudioFileRead.prepare { _ in
                    precondition(!Thread.isMainThread)
                    precondition(probe.add("active") == 1, "Idle decoding must stay bounded across project tabs")
                    defer { probe.add("active", -1) }
                    Thread.sleep(forTimeInterval: 0.002)
                    return 1
                }
            }
        }
        var total = 0
        for try await value in group { total += value }
        precondition(total == 12, "A decoder failure must not poison subsequent preparation")
    }
    print("IDLE_MEDIA_WORKER_CANCELLATION_AND_SERIAL_BOUND_OK")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("idle-media-generation-" + UUID().uuidString)
    let oldRoot = root.appendingPathComponent("Old"), newRoot = root.appendingPathComponent("New")
    try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    for (directory, value) in [(oldRoot, Float(0.1)), (newRoot, Float(0.3))] {
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
        pcm.frameLength = pcm.frameCapacity
        for channel in 0..<2 { pcm.floatChannelData![channel].update(repeating: value, count: Int(pcm.frameLength)) }
        let file = try AVAudioFile(forWriting: directory.appendingPathComponent("same.wav"), settings: format.settings)
        try file.write(from: pcm)
    }
    var project = Project.empty(name: "Same identities across a project replacement")
    var track = Track(id: UUID(), name: "Stem", role: .other)
    track.clips = [AudioClip(id: UUID(), name: "Same basename", startTime: 0, duration: 1,
                            audioFile: AudioFile(path: "same.wav"))]
    project.songs[0].tracks = [track]; project.songs[0].duration = 1
    var state = ShowSnapshot(project: project, transport: TransportState(playing: false,
        songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false),
        subPlay: SubPlayState(playing: false, position: 0)))
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let audio = StemAudioPlayback(engine: engine, realtime: false)
    defer { audio.prepareForClosing() }
    var failures: [Error] = []
    audio.onError = { failures.append($0) }

    let resetGate = DispatchSemaphore(value: 0)
    let blocker = Task {
        try await AudioFileRead.prepare { _ in
            probe.add("resetBlocked")
            precondition(resetGate.wait(timeout: .now() + 5) == .success)
            return 0
        }
    }
    try await waitUntil { probe.count("resetBlocked") == 1 }
    audio.open(directory: oldRoot)
    try audio.update(state, revision: 1)
    for _ in 0..<10 { await Task.yield() }
    audio.open(directory: newRoot)
    try audio.update(state, revision: 1)
    resetGate.signal()
    _ = try await blocker.value
    try await waitUntil { engine.attachedNodes.contains { $0 is AVAudioPlayerNode } }
    let cached = Mirror(reflecting: audio).children.first { $0.label == "files" }!.value as! [String: AVAudioFile]
    precondition(cached["same.wav"]?.url == newRoot.appendingPathComponent("same.wav"),
                 "A late worker result must not replace media in the next project")
    precondition(failures.isEmpty)
    state.transport.playing = true
    try audio.update(state, revision: 1)
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    var peak: Float = 0
    for block in 0..<48 {
        let status = try engine.renderOffline(512, to: pcm)
        precondition(status == .success)
        if block >= 24 {
            for i in 0..<Int(pcm.frameLength) { peak = max(peak, abs(pcm.floatChannelData![0][i])) }
        }
    }
    precondition(abs(peak - 0.3) < 0.0001, "Prepared playback used stale project PCM: \(peak)")
    print("IDLE_MEDIA_PROJECT_GENERATION_PCM_OK", rate)
}

Task { @MainActor in do { try await run(); exit(0) } catch { print(error); exit(1) } }
dispatchMain()
