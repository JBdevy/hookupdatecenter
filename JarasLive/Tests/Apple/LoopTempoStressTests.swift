import Foundation
import AVFoundation
import Darwin

setbuf(stdout, nil)
func require(_ value: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "Failed assertion") {
    if !value() { print("STRESS_FAILURE", message()); exit(1) }
}

@MainActor private func clocks(_ audio: StemAudioPlayback) -> [Int: (position: Double, host: UInt64)] {
    Mirror(reflecting: audio).children.first { $0.label == "headAudioClock" }!.value as! [Int: (position: Double, host: UInt64)]
}

@MainActor private func sampledAt(host: UInt64, offset: Double = 0) -> Double {
    ProcessInfo.processInfo.systemUptime + AVAudioTime.seconds(forHostTime: host)
        - AVAudioTime.seconds(forHostTime: mach_absolute_time()) + offset
}

@MainActor private func testPlaybackPresentation() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-presentation-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    if CommandLine.arguments.contains("--legacy") { setenv("CATLIVE_PREPARED_SOURCE", "0", 1) }
    let voiceCount = Int(ProcessInfo.processInfo.environment["CATLIVE_TEST_VOICES"] ?? "200") ?? 200
    let sourceRate = Double(ProcessInfo.processInfo.environment["CATLIVE_TEST_SOURCE_RATE"] ?? "44100") ?? 44100
    let format = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 2)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sourceRate * 30))!
    pcm.frameLength = pcm.frameCapacity
    for channel in 0..<2 { pcm.floatChannelData![channel].update(repeating: 0.04, count: Int(pcm.frameLength)) }
    try AVAudioFile(forWriting: folder.appendingPathComponent("tone.wav"), settings: format.settings).write(from: pcm)
    let engine = AVAudioEngine()
    let audio = StemAudioPlayback(engine: engine, auxiliarySelectedHardware: true)
    audio.setLicenseAllowed(false) // Mute only physical output, retaining PCM at the capture tap.
    try audio.startDeviceSession(); audio.open(directory: folder)
    defer { audio.prepareForClosing() }
    var project = Project.empty(name: "Presentation clock")
    var track = Track(id: UUID(), name: "Loop source", role: .other)
    track.clips = [AudioClip(id: UUID(), name: "Tone", startTime: 0, duration: 30, audioFile: AudioFile(path: "tone.wav"))]
    project.songs[0].tracks = (0..<voiceCount).map { index in
        var copy = track; if index > 0 { copy.id = UUID(); copy.clips[0].id = UUID() }
        copy.clips[0].playbackRate = 1.0.nextDown
        return copy
    }; project.songs[0].duration = 30; project.songs[0].timeSettings = ProjectTimeSettings()
    var state = ShowSnapshot(project: project, transport: TransportState(playing: false,
        songId: project.songs[0].id, position: 1, queue: QueueState(), loop: LoopState(enabled: true, start: 1, end: 1.6),
        subPlay: SubPlayState(playing: false, position: 0)))
    try audio.update(state, revision: 1)
    if let preparation = try audio.pendingPlaybackPreparation(state, revision: 1) { await preparation.value }
    try await Task.sleep(nanoseconds: 250_000_000)
    for track in project.songs[0].tracks { _ = audio.meter(for: track.id) }
    print("STRESS_PREPARED", voiceCount, audio.bufferedAudioDiagnostics() ?? [:])
    let ring = JarasCaptureRing(channels: 2, capacity: 262144); ring.beginCapture()
    _ = try audio.attachOutputCapture(track.id, postFX: true, postFader: true, ring: ring)
    var buffer = [Float](repeating: 0, count: 65536)
    func drain() -> [Float] {
        let count = buffer.withUnsafeMutableBufferPointer { ring.readFrames($0.baseAddress!, maximum: 32768) }
        return stride(from: 0, to: Int(count) * 2, by: 2).map { buffer[$0] }
    }
    _ = drain()
    let began = ProcessInfo.processInfo.systemUptime
    state.transport.playing = true
    try audio.update(state, revision: 1, sampledAt: began)
    require(engine.mainMixerNode.outputVolume == 0, "Fixture must remain muted at physical output")
    print("STRESS_FIRST_PLAY_MS", (ProcessInfo.processInfo.systemUptime - began) * 1000)
    let initial = clocks(audio)[0]!
    let waiting = audio.presentationPosition(head: 0, sampledAt: sampledAt(host: initial.host, offset: -0.01))!
    require(abs(waiting - 1) < 0.0001, "First Play must not show before its requested position")
    var serial: UInt64 = 0, promoted = 0, futurePromoted = 0
    var signal: [Float] = []
    while ProcessInfo.processInfo.systemUptime - began < 2.05 {
        try await Task.sleep(nanoseconds: 5_000_000)
        let sample = ProcessInfo.processInfo.systemUptime
        let elapsed = sample - began
        let nextSerial = UInt64(floor(elapsed / 0.6))
        let prior = clocks(audio)[0]!
        state.transport.position = 1 + elapsed.truncatingRemainder(dividingBy: 0.6)
        state.transport.sectionJumpSerial = nextSerial
        let updateBegan = ProcessInfo.processInfo.systemUptime
        try audio.update(state, revision: 1, sampledAt: sample)
        let updateMS = (ProcessInfo.processInfo.systemUptime - updateBegan) * 1000
        if updateMS > 30 { print("STRESS_SLOW_UPDATE", elapsed, updateMS, "serial", nextSerial, "clocks", clocks(audio)) }
        if nextSerial != serial {
            let next = clocks(audio)[0]!
            require(next.position == 1, "Prepared loop destination: next=\(next), prior=\(prior), elapsed=\(elapsed), serial=\(nextSerial), promotions=\(promoted), updateMS=\(updateMS)")
            let duration = AVAudioTime.seconds(forHostTime: next.host - prior.host)
            require(abs(duration - 0.6) < 0.000001, "Presentation must not alter the PCM loop deadline")
            let before = audio.presentationPosition(head: 0, sampledAt: sampledAt(host: next.host, offset: -0.001))!
            // Converting between uptime and host time has sub-microsecond sampling error.
            // The pure clock test covers exact equality; here query 10 microseconds after it.
            let boundary = audio.presentationPosition(head: 0, sampledAt: sampledAt(host: next.host, offset: 0.00001))!
            require(abs(before - 1.599) < 0.0001, "Needle must reach the outgoing marker: \(before)")
            require(abs(boundary - 1) < 0.0001, "Needle must return exactly at the scheduled first marker: \(boundary)")
            if next.host > mach_absolute_time() { futurePromoted += 1 }
            promoted += 1
        }
        serial = nextSerial
        let samples = drain()
        if elapsed > 0.3 { signal.append(contentsOf: samples) }
    }
    require(promoted >= 3 && futurePromoted > 0, "Fixture must exercise transport promotion before audible output")
    var longestSilence = 0, silence = 0
    for value in signal {
        silence = abs(value) < 0.001 ? silence + 1 : 0
        longestSilence = max(longestSilence, silence)
    }
    let active = signal.filter { abs($0) > 0.01 }.count
    require(signal.count > 48000 && active > signal.count * 98 / 100 && longestSilence < 480,
                 "Loop PCM must remain continuous: active=\(active)/\(signal.count), longest silence=\(longestSilence)")
    print("PRESENTATION_REAL_LOOP_PCM_OK promotions=\(promoted) future=\(futurePromoted) longest_silence_frames=\(longestSilence)")

    var revision: UInt64 = 1
    var last = ProcessInfo.processInfo.systemUptime
    for step in 0..<450 {
        try await Task.sleep(nanoseconds: 30_000_000)
        let now = ProcessInfo.processInfo.systemUptime
        state.transport.position += now - last
        last = now
        let low = state.transport.loop.start!, high = state.transport.loop.end!
        if state.transport.position >= high {
            let loops = floor((state.transport.position-low)/(high-low))
            serial += UInt64(loops)
            state.transport.position = low+(state.transport.position-low).truncatingRemainder(dividingBy: high-low)
            state.transport.sectionJumpSerial = serial
        }
        if step % 3 == 0 {
            let bpm = state.project.songs[0].bpm + (step % 180 < 90 ? 1 : -1)
            let ratio = state.project.songs[0].bpm / bpm
            state.project.songs[0].followTempo(bpm)
            state.transport.position *= ratio
            state.transport.loop.start! *= ratio
            state.transport.loop.end! *= ratio
            revision += 1
        }
        try audio.update(state, revision: revision, sampledAt: now)
        if step % 30 == 0 { print("LOOP_TEMPO",step,audio.bufferedAudioDiagnostics() ?? [:]);  }
    }
    if let diagnostics = audio.bufferedAudioDiagnostics() {
        require((diagnostics["underruns"] as? NSNumber)?.intValue == 0 &&
                (diagnostics["renderFailures"] as? NSNumber)?.intValue == 0,
                "Output emptied during rapid tempo edits and loops: \(diagnostics)")
    }
    require(state.project.songs[0].tracks.allSatisfy { audio.meter(for: $0.id).level > 0.005 },
            "Every independent track must remain audible")
    print("LOOP_TEMPO_150_EDITS_200_TRACKS_OK",audio.bufferedAudioDiagnostics() ?? [:])
    audio.stop()
    return

}
Task { @MainActor in
    do {
        UserDefaults.standard.setVolatileDomain(["jaras.metronome.enabled": false], forName: UserDefaults.argumentDomain)
        try await testPlaybackPresentation()
        exit(0)
    } catch { print("AUDIO_PRESENTATION_PLAYBACK_ERROR", error); exit(1) }
}
dispatchMain()
