import Foundation
import AVFoundation
import Darwin
setbuf(stdout, nil)

@MainActor func run() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-subplay-prime-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 10)!
    pcm.frameLength = pcm.frameCapacity
    for channel in 0..<2 { for frame in 0..<Int(pcm.frameLength) {
        pcm.floatChannelData![channel][frame] = frame < 44100 * 5 ? 0.01 : 0.02
    } }
    try AVAudioFile(forWriting: folder.appendingPathComponent("source.wav"), settings: format.settings).write(from: pcm)
    let count = Int(ProcessInfo.processInfo.environment["CATLIVE_TEST_VOICES"] ?? "32") ?? 32
    var project = Project.empty(name: "Subplay preparation")
    project.songs[0].tracks = try (0..<count).map { index in
        let path = "\(index).wav"
        try FileManager.default.linkItem(at: folder.appendingPathComponent("source.wav"), to: folder.appendingPathComponent(path))
        var track = Track(id: UUID(), name: path, role: .other)
        track.clips = [AudioClip(id: UUID(), name: path, startTime: 0, duration: 10, audioFile: AudioFile(path: path))]
        return track
    }
    project.songs[0].duration = 10
    let audio = StemAudioPlayback(engine: AVAudioEngine(), auxiliarySelectedHardware: true)
    audio.setLicenseAllowed(false)
    try audio.startDeviceSession(); audio.open(directory: folder)
    defer { audio.prepareForClosing() }
    var state = ShowSnapshot(project: project, transport: TransportState(playing: false,
        songId: project.songs[0].id, position: 1, queue: QueueState(), loop: LoopState(enabled: false),
        subPlay: SubPlayState(playing: false, position: 5)))
    try audio.update(state, revision: 1)
    if let preparation = try audio.pendingPlaybackPreparation(state, revision: 1) { await preparation.value }
    let master = Mirror(reflecting: audio).children.first { $0.label == "masterBus" }!.value as! AVAudioMixerNode
    let capture = JarasCaptureRing(channels: 2, capacity: 262144); capture.beginCapture()
    master.installTap(onBus: 0, bufferSize: 512, format: master.outputFormat(forBus: 0)) { pcm, _ in capture.push(pcm) }
    defer { if master.engine != nil { master.removeTap(onBus: 0) } }
    var samples = [Float](repeating: 0, count: 65536)
    func peak() -> Float {
        var peak: Float = 0
        while true {
            let count = samples.withUnsafeMutableBufferPointer { capture.readFrames($0.baseAddress!, maximum: 32768) }
            if count == 0 { return peak }
            for index in 0..<Int(count)*2 { peak = max(peak, abs(samples[index])) }
        }
    }
    state.transport.playing = true
    let start = ProcessInfo.processInfo.systemUptime
    try audio.update(state, revision: 1, sampledAt: start)
    try await Task.sleep(nanoseconds: 250_000_000)
    precondition(abs(peak() - Float(count) * 0.01) < 0.005)
    let task = audio.pendingSubplayPreparation(state, revision: 1)!
    var finished = false, heartbeats = 0
    Task { @MainActor in await task.value; finished = true }
    while !finished {
        state.transport.position = 1 + ProcessInfo.processInfo.systemUptime - start
        try audio.update(state, revision: 1)
        heartbeats += 1
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    precondition(heartbeats > 1, "Main-actor transport/UI work must continue during decoder preparation")
    precondition(audio.pendingSubplayPreparation(state, revision: 1) == nil, "The completed request must not restart preparation")
    precondition(abs(peak() - Float(count) * 0.01) < 0.005, "Incoming priming must not leak or interrupt main-head PCM")
    state.transport.subPlay.playing = true
    let commit = ProcessInfo.processInfo.systemUptime
    try audio.update(state, revision: 1)
    let commitMs = (ProcessInfo.processInfo.systemUptime - commit) * 1000
    try await Task.sleep(nanoseconds: 250_000_000)
    precondition(abs(peak() - Float(count) * 0.03) < 0.01, "The incoming head must start from its requested position and sum with Play")
    state.transport.subPlay.playing = false
    try audio.update(state, revision: 1)
    state.transport.subPlay.position = 6
    let canceled = audio.pendingSubplayPreparation(state, revision: 1)!
    try await Task.sleep(nanoseconds: 2_000_000)
    canceled.cancel(); await canceled.value
    let reserved = Mirror(reflecting: audio).children.first { $0.label == "subplayReserved" }!.value as! [UUID: [Any]]
    precondition(reserved.isEmpty, "Canceled preparation must release its silent reservations after its worker finishes")
    state.transport.playing = false
    try audio.update(state, revision: 1)
    master.removeTap(onBus: 0)
    try FileManager.default.removeItem(at: folder)
    print("SUBPLAY_BACKGROUND_PRIMING_UI_HEARTBEAT_MAIN_PCM_INCOMING_POSITION_SUM_CANCEL_OK voices=\(count) heartbeats=\(heartbeats) commitMs=\(commitMs)")
    exit(0) // Keep disposal of the synthetic graph outside the playback measurement.
}
Task { @MainActor in do { try await run(); exit(0) } catch { print(error); exit(1) } }
dispatchMain()
