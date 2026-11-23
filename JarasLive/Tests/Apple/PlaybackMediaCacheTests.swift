import AVFoundation
import Darwin
import Foundation

@MainActor private func run() async throws {
    // Exercise the descriptor allowance of a macOS application launched from Finder.
    var previous = rlimit()
    precondition(getrlimit(RLIMIT_NOFILE, &previous) == 0)
    var limited = previous
    limited.rlim_cur = min(limited.rlim_cur, 256)
    precondition(setrlimit(RLIMIT_NOFILE, &limited) == 0)
    defer { _ = setrlimit(RLIMIT_NOFILE, &previous) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-reader-cache-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(rate))!
    pcm.frameLength = pcm.frameCapacity
    for channel in 0..<2 { pcm.floatChannelData![channel].update(repeating: 0.125, count: Int(pcm.frameLength)) }
    let source = root.appendingPathComponent("source.wav")
    try AVAudioFile(forWriting: source, settings: format.settings).write(from: pcm)
    var track = Track(id: UUID(), name: "Pad", role: .other)
    for index in 0..<300 {
        let path = "stem-\(index).wav"
        try FileManager.default.linkItem(at: source, to: root.appendingPathComponent(path))
        track.clips.append(AudioClip(id: UUID(), name: path, startTime: Double(index * 4), duration: 1,
                                     audioFile: AudioFile(path: path)))
    }
    var project = Project.empty(name: "Long set")
    project.songs[0].duration = 1200
    project.songs[0].tracks = [track]
    let engine = AVAudioEngine(), driver = JarasMobileAudioOutput(engine: engine)
    let outFormat = try driver.configure(withSampleRate: rate, channels: 2)
    let audio = StemAudioPlayback(engine: engine, realtime: true, mobileOutput: driver)
    defer { driver.stop(); audio.prepareForClosing() }
    var errors: [String] = []
    audio.onError = { errors.append($0.localizedDescription) }
    audio.open(directory: root)
    var state = ShowSnapshot(project: project, transport: TransportState(playing: false, songId: project.songs[0].id,
        position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    for index in Array(track.clips.indices) + [1] {
        state.transport.editPosition = track.clips[index].startTime
        state.transport.position = track.clips[index].startTime
        try audio.update(state, revision: 1)
        if let task = try audio.pendingPlaybackPreparation(state, revision: 1) { await task.value }
        if !errors.isEmpty { throw NSError(domain: "Valid stem \(index): \(errors)", code: 1) }
    }
    state.transport.playing = true
    try audio.update(state, revision: 1)
    let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 512)!
    output.frameLength = 512
    var peak: Float = 0
    for _ in 0..<32 {
        var stamp = AudioTimeStamp()
        stamp.mHostTime = mach_absolute_time()
        stamp.mSampleTime = Double(engine.manualRenderingSampleTime)
        stamp.mFlags = [.hostTimeValid,.sampleTimeValid]
        var flags = AudioUnitRenderActionFlags()
        precondition(driver.renderFrames(512, time: &stamp, flags: &flags, buffers: output.mutableAudioBufferList) == noErr)
        for i in 0..<512 { peak = max(peak, abs(output.floatChannelData![0][i])) }
        try await Task.sleep(nanoseconds: UInt64(512e9/rate))
    }
    precondition(errors.isEmpty && abs(peak - 0.125) < 0.002, "Revisiting an evicted stem must reopen and play real PCM")
    let unavailable = track.clips[41]
    try FileManager.default.removeItem(at: root.appendingPathComponent(unavailable.audioFile!.path))
    state.transport.playing = false
    state.transport.editPosition = unavailable.startTime
    state.transport.position = unavailable.startTime
    try audio.update(state, revision: 1)
    if let task = try audio.pendingPlaybackPreparation(state, revision: 1) { await task.value }
    precondition(errors.count == 1, "A genuinely missing stem must still report its failure")
    let openFDs = (0..<Int32(limited.rlim_cur)).filter { fcntl($0, F_GETFD) >= 0 }.count
    print("LONG_SET_READER_CACHE_OK", Int(rate), "paths", track.clips.count, "open descriptors", openFDs, "revisit peak", peak)
}

setbuf(stdout, nil)
Task { @MainActor in do { try await run(); exit(0) } catch { print(error); exit(1) } }
dispatchMain()
