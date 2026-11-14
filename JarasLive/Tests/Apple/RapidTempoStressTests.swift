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
    let sourceRate = Double(ProcessInfo.processInfo.environment["CATLIVE_TEST_SOURCE_RATE"] ?? "48000") ?? 48000
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
        copy.clips[0].playbackRate = 1.12
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

    // Cancel the next prepared jump. It must never become a visual handoff.
    state.transport.loop.enabled = false
    let canceled = ProcessInfo.processInfo.systemUptime
    try audio.update(state, revision: 1, sampledAt: canceled)
    require(clocks(audio)[2] == nil, "Disabling loop cancels its prepared clock")
    let beforeCancel = audio.presentationPosition(head: 0, sampledAt: canceled)!
    try await Task.sleep(nanoseconds: 650_000_000)
    state.transport.position += ProcessInfo.processInfo.systemUptime - canceled
    try audio.update(state, revision: 1)
    require(audio.presentationPosition(head: 0, sampledAt: ProcessInfo.processInfo.systemUptime)! > beforeCancel + 0.6,
                 "Canceled future loop must not reposition the needle")

    // Explicit seek discards every outgoing display segment.
    state.transport.position = 4; state.transport.sectionJumpSerial = serial + 1
    try audio.update(state, revision: 1)
    let seek = clocks(audio)[0]!
    require(abs(audio.presentationPosition(head: 0, sampledAt: sampledAt(host: seek.host, offset: -0.01))! - 4) < 0.0001)
    state.transport.subPlay = SubPlayState(playing: true, position: 2)
    try audio.update(state, revision: 1)
    try await Task.sleep(nanoseconds: 200_000_000)
    let sub = clocks(audio)[1]!
    let sample = ProcessInfo.processInfo.systemUptime
    let audibleSub = audio.presentationPosition(head: 1, sampledAt: sample)!
    state.transport.position = 2.2; state.transport.subPlay.position = 2.2
    state.transport.subPlay.playing = false; state.transport.subPlayPromotion = 1
    try audio.update(state, revision: 1, sampledAt: sample)
    require(clocks(audio)[0]!.host == sub.host && clocks(audio)[1] == nil,
                 "SubPlay must promote the existing PCM clock")
    require(abs(audio.presentationPosition(head: 0, sampledAt: sample)! - audibleSub) < 0.0001,
                 "SubPlay visual promotion must retain its audible position")
    var revision: UInt64 = 1
    for bpm in [135.0, 90, 156, 120] {
        let scale = state.project.songs[0].bpm / bpm
        state.project.songs[0].followTempo(bpm)
        state.transport.position *= scale
        state.transport.subPlay.position = state.transport.position
        revision += 1
        let began = ProcessInfo.processInfo.systemUptime, initialPosition = state.transport.position
        try audio.update(state, revision: revision, sampledAt: began)
        let editMS = (ProcessInfo.processInfo.systemUptime - began) * 1000
        while ProcessInfo.processInfo.systemUptime - began < 1.0 {
            try await Task.sleep(nanoseconds: 20_000_000)
            let now = ProcessInfo.processInfo.systemUptime
            state.transport.position = initialPosition + now - began
            try audio.update(state, revision: revision, sampledAt: now)
        }
        let levels = state.project.songs[0].tracks.map { audio.meter(for: $0.id).level }
        let audible = levels.filter { $0 > 0.005 }.count
        print("STRESS_LIVE_BPM", bpm, "edit_ms", editMS, "audible", audible, "min", levels.min() ?? 0, "max", levels.max() ?? 0, "sum", levels.reduce(0,+), "master", audio.masterMeter.level)
        require(audible == voiceCount, "Every track must remain audible after BPM changes")
        require(abs(audio.masterMeter.level - levels.reduce(0,+)) < max(0.002, levels.reduce(0,+) * 0.08), "Duplicated tracks must sum independently after BPM changes")
    }
    // Repeated + presses while the render thread is pulling 200 sources.
    // A whole-project edit must become audible on one common render boundary.
    for round in 0..<3 {
        for step in 0..<30 {
            let sample = ProcessInfo.processInfo.systemUptime
            let bpm = state.project.songs[0].bpm + (round == 1 ? -1 : 1)
            let scale = state.project.songs[0].bpm / bpm
            state.project.songs[0].followTempo(bpm)
            state.transport.position *= scale
            state.transport.subPlay.position = state.transport.position
            revision += 1
            try audio.update(state, revision: revision, sampledAt: sample)
            try await Task.sleep(nanoseconds: 25_000_000)
            let now = ProcessInfo.processInfo.systemUptime
            state.transport.position += now - sample
            try audio.update(state, revision: revision, sampledAt: now)
            if step % 10 == 9 { print("RAPID_BPM",round,step,bpm,audio.bufferedAudioDiagnostics() ?? [:]) }
        }
        let sample = ProcessInfo.processInfo.systemUptime, pos = state.transport.position
        while ProcessInfo.processInfo.systemUptime - sample < 0.4 {
            try await Task.sleep(nanoseconds: 20_000_000)
            let now = ProcessInfo.processInfo.systemUptime
            state.transport.position = pos + now - sample
            try audio.update(state, revision: revision, sampledAt: now)
        }
        let levels = state.project.songs[0].tracks.map { audio.meter(for: $0.id).level }
        require(levels.allSatisfy { $0 > 0.005 }, "Every track must remain audible after rapid BPM edits")
    }
    if let stats = audio.bufferedAudioDiagnostics() {
        require((stats["underruns"] as? NSNumber)?.intValue == 0 && (stats["renderFailures"] as? NSNumber)?.intValue == 0, "Hardware output must remain fed during BPM, loops and seeks: \(stats)")
    }
    print("STRESS_FINISHED", voiceCount, audio.bufferedAudioDiagnostics() ?? [:])
    audio.stop()
    require(audio.presentationPosition(head: 0, sampledAt: sample) == nil && audio.presentationPosition(head: 1, sampledAt: sample) == nil)
    state.transport.playing = false
    var another = project.songs[0]; another.id = UUID()
    state.project.songs.append(another); state.transport.songId = another.id
    try audio.update(state, revision: revision + 1)
    require(audio.presentationPosition(head: 0, sampledAt: sample) == nil, "Song change must clear old clocks")
    audio.open(directory: folder)
    require(audio.presentationPosition(head: 0, sampledAt: sample) == nil, "Opening a document must clear old clocks")
    print("PRESENTATION_REAL_CANCEL_SEEK_SUBPLAY_STOP_SONG_OPEN_OK")
}

Task { @MainActor in
    do {
        UserDefaults.standard.setVolatileDomain(["jaras.metronome.enabled": false], forName: UserDefaults.argumentDomain)
        try await testPlaybackPresentation()
        exit(0)
    } catch { print("AUDIO_PRESENTATION_PLAYBACK_ERROR", error); exit(1) }
}
dispatchMain()
