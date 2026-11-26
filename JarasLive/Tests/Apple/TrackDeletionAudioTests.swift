import AVFoundation
import Foundation
import Darwin

setbuf(stdout, nil)

@MainActor func run() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-delete-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 8)!
    buffer.frameLength = buffer.frameCapacity
    for channel in 0..<2 { buffer.floatChannelData![channel].update(repeating: 0.02, count: Int(buffer.frameLength)) }
    try AVAudioFile(forWriting: folder.appendingPathComponent("source.wav"), settings: format.settings).write(from: buffer)
    let hardware = AVAudioEngine()
    let audio = StemAudioPlayback(engine: hardware, auxiliarySelectedHardware: true)
    audio.setLicenseAllowed(false)
    try audio.startDeviceSession()
    audio.open(directory: folder)
    defer { audio.prepareForClosing() }
    var project = Project.empty(name: "Track deletion")
    project.songs[0].tracks = (0..<32).map { index in
        var track = Track(id: UUID(), name: "Track \(index)", role: .other)
        track.clips = [AudioClip(id: UUID(), name: "Audio", startTime: 0, duration: 8, audioFile: AudioFile(path: "source.wav"))]
        return track
    }
    project.songs[0].duration = 8
    var state = ShowSnapshot(project: project, transport: TransportState(playing: false,
        songId: project.songs[0].id, position: 0.25, queue: QueueState(),
        loop: LoopState(enabled: false, start: 0, end: 0), subPlay: SubPlayState(playing: false, position: 0)))
    try audio.update(state, revision: 1)
    if let preparation = try audio.pendingPlaybackPreparation(state, revision: 1) { await preparation.value }
    let graph = Mirror(reflecting: audio).children.first { $0.label == "engine" }!.value as! AVAudioEngine
    let master = Mirror(reflecting: audio).children.first { $0.label == "masterBus" }!.value as! AVAudioMixerNode
    let capture = JarasCaptureRing(channels: 2, capacity: 262144)
    capture.beginCapture()
    master.installTap(onBus: 0, bufferSize: 512, format: master.outputFormat(forBus: 0)) { pcm, _ in capture.push(pcm) }
    defer { if master.engine != nil { master.removeTap(onBus: 0) } }
    var samples = [Float](repeating: 0, count: 65536)
    func peak() -> Float {
        var result: Float = 0
        while true {
            let count = samples.withUnsafeMutableBufferPointer { capture.readFrames($0.baseAddress!, maximum: 32768) }
            if count == 0 { return result }
            for index in 0..<Int(count) * 2 { result = max(result, abs(samples[index])) }
        }
    }
    func pending() -> Int {
        (Mirror(reflecting: audio).children.first { $0.label == "deletedVoices" }!.value as! [Any]).count
    }
    state.transport.playing = true
    try audio.update(state, revision: 1)
    try await Task.sleep(nanoseconds: 350_000_000)
    let before = peak()
    precondition(abs(before - 0.64) < 0.005, "The original mix must reach real master PCM")
    let attached = graph.attachedNodes.count
    state.project.songs[0].tracks.removeLast(16)
    state.transport.position = 0.6
    let began = ProcessInfo.processInfo.systemUptime
    try audio.update(state, revision: 2)
    let deletionMs = (ProcessInfo.processInfo.systemUptime - began) * 1000
    precondition(pending() > 0, "Deletion must publish before disposing the removed source graph")
    precondition(graph.attachedNodes.count == attached, "The Delete action must not synchronously detach all item processors")
    for _ in 0..<1000 {
        if pending() == 0 { break }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    precondition(pending() == 0 && graph.attachedNodes.count < attached, "Deferred resources must actually be released")
    _ = peak()
    try await Task.sleep(nanoseconds: 350_000_000)
    let after = peak()
    precondition(abs(after - 0.32) < 0.005, "Deleted sources stay silent and all surviving tracks keep their PCM")
    state.transport.playing = false
    try audio.update(state, revision: 2)
    state.project.songs[0].tracks.removeAll()
    try audio.update(state, revision: 3)
    precondition(pending() > 0)
    audio.open(directory: folder)
    precondition(pending() == 0, "A project change must drain cleanup before rebuilding its graph")
    print("TRACK_DELETE_RESPONSIVE_RELEASE_SURVIVING_PCM_PROJECT_SWAP_OK deleteMs=\(deletionMs) before=\(before) after=\(after)")
}
Task { @MainActor in do { try await run(); exit(0) } catch { print(error); exit(1) } }
dispatchMain()
