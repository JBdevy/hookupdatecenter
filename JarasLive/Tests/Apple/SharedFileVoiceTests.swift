import Foundation
import AVFoundation
import Darwin

setbuf(stdout, nil)
private func require(_ value: Bool, _ message: String) {
    if !value { print("SHARED_VOICES_FAILURE", message); exit(1) }
}
private func member(_ value: Any, _ name: String) -> Any {
    Mirror(reflecting: value).children.first { $0.label == name }!.value
}
private func values(_ dictionary: Any) -> [Any] {
    Mirror(reflecting: dictionary).children.map { member($0.value, "value") }
}
@MainActor private func run(hardware: Bool) async throws {
    let targetCount = max(1, min(1024, Int(ProcessInfo.processInfo.environment["CATLIVE_TEST_VOICES"] ?? "119") ?? 119))
    let observationFrames = max(45, min(900, Int(ProcessInfo.processInfo.environment["CATLIVE_TEST_OBSERVATION_FRAMES"] ?? "45") ?? 45))
    UserDefaults.standard.setVolatileDomain(["jaras.metronome.enabled": false], forName: UserDefaults.argumentDomain)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-shared-voices-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let rate = 44100.0, format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    let wav = folder.appendingPathComponent("tone.wav"), mp3 = folder.appendingPathComponent("tone.mp3")
    try autoreleasepool {
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88200)!
        pcm.frameLength = pcm.frameCapacity
        for ch in 0..<2 { for frame in 0..<Int(pcm.frameLength) {
            pcm.floatChannelData![ch][frame] = Float(0.004 * sin(Double(frame) * 2 * .pi * 440 / rate))
        } }
        try AVAudioFile(forWriting: wav, settings: format.settings).write(from: pcm)
    }
    try JarasMP3Encoder.encodeWav(wav, to: mp3)
    let engine = AVAudioEngine()
    if !hardware { try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512) }
    let audio = StemAudioPlayback(engine: engine, realtime: true, auxiliarySelectedHardware: hardware)
    audio.setLicenseAllowed(!hardware)
    if hardware { try audio.startDeviceSession() }
    audio.open(directory: folder)
    defer { audio.prepareForClosing() }
    var failures: [String] = []; audio.onError = { failures.append($0.localizedDescription) }
    var project = Project.empty(name: "Shared reader regression")
    project.songs[0].duration = 120
    let originals = (0..<targetCount).map { index -> Track in
        var track = Track(id: UUID(), name: "Copy \(index)", role: .keys)
        var clip = AudioClip(id: UUID(), name: "Same MP3", startTime: 0, duration: 120, audioFile: AudioFile(path: "tone.mp3"))
        clip.loopLength = 2
        track.clips = [clip]
        return track
    }
    let cold = CommandLine.arguments.contains("--cold")
    project.songs[0].tracks = hardware && !cold ? Array(originals.prefix(1)) : originals
    var state = ShowSnapshot(project: project, transport: TransportState(playing: false, songId: project.songs[0].id,
        position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    var limit = rlimit(); require(getrlimit(RLIMIT_NOFILE, &limit) == 0, "read descriptor limit")
    var low = limit; low.rlim_cur = min(rlim_t(ProcessInfo.processInfo.environment["CATLIVE_TEST_FD_LIMIT"].flatMap(UInt64.init) ?? 64), limit.rlim_cur)
    require(setrlimit(RLIMIT_NOFILE, &low) == 0, "set fixture-only descriptor limit")
    defer { _ = setrlimit(RLIMIT_NOFILE, &limit) }
    var revision: UInt64 = 1
    try audio.update(state, revision: revision)
    if hardware, let preparation = try audio.pendingPlaybackPreparation(state, revision: revision) {
        let began = ProcessInfo.processInfo.systemUptime
        await preparation.value
        print("SHARED_PREPLAY_MS", (ProcessInfo.processInfo.systemUptime - began) * 1000)
    }
    func inspect(_ expected: Int) {
        let voices = values(member(audio, "voices"))
        require(voices.count == expected, "every copy needs a scheduled source: \(voices.count)/\(expected), errors: \(failures)")
        let files = Set(voices.map { ObjectIdentifier(member($0, "file") as! AVAudioFile) })
        require(files.count == 1, "prepared copies must share metadata instead of opening private readers")
        for voice in voices {
            require(Mirror(reflecting: member(voice, "stretch")).children.isEmpty &&
                    Mirror(reflecting: member(voice, "rateClock")).children.isEmpty,
                    "prepared copies must not allocate unused legacy pitch processors")
            let source = Mirror(reflecting: member(voice, "prepared")).children.first!.value as! JarasPreparedClip
            require(source.underruns == 0, "a copied source missed decoded PCM")
        }
        require(failures.isEmpty, "valid shared media must never enter the failed-media ledger")
    }
    func reportDeadline(_ label: String) {
        let now = mach_absolute_time()
        let remaining = values(member(audio, "voices")).compactMap { voice -> Double? in
            let value = Mirror(reflecting: member(voice, "scheduledOnset")).children.first?.value as? AVAudioTime
            guard let value, value.isHostTimeValid else { return nil }
            return (value.hostTime >= now ? AVAudioTime.seconds(forHostTime: value.hostTime - now) : -AVAudioTime.seconds(forHostTime: now - value.hostTime)) * 1000
        }
        print("SHARED_ONSET_REMAINING_MS", label, remaining.min() ?? 0, remaining.max() ?? 0)
    }
    if hardware {
        var origin = ProcessInfo.processInfo.systemUptime
        state.transport.playing = true; try audio.update(state, revision: revision)
        reportDeadline("start")
        origin = ProcessInfo.processInfo.systemUptime
        let stages = Array(Set([1, 19, 51, 73, 98, 119, 256, 512, targetCount].filter { $0 <= targetCount })).sorted()
        for count in (cold ? [targetCount] : stages) {
            state.project.songs[0].tracks = Array(originals.prefix(count)); revision += 1
            for track in state.project.songs[0].tracks { _ = audio.meter(for: track.id) }
            let before = ProcessInfo.processInfo.systemUptime
            for _ in 0..<observationFrames {
                state.transport.position = ProcessInfo.processInfo.systemUptime - origin
                try audio.update(state, revision: revision)
                try await Task.sleep(nanoseconds: 30_000_000)
            }
            let audible = originals.prefix(count).filter { audio.meter(for: $0.id).level > 0.002 }.count
            print("SHARED_LIVE_MP3", count, "audible", audible, "master", audio.masterMeter.level,
                  "elapsed", ProcessInfo.processInfo.systemUptime - before)
            if audible != count {
                for voice in values(member(audio, "voices")) {
                    let clip = member(voice, "clip") as! AudioClip, track = member(voice, "track") as! UUID
                    let source = Mirror(reflecting: member(voice, "prepared")).children.first!.value as! JarasPreparedClip
                    print("VOICE_STATE", originals.firstIndex(where: { $0.id == track }) ?? -1, "meter", audio.meter(for: track).level,
                          "source", source.sourcePosition, "running", source.playing, "underruns", source.underruns, "clipStart", clip.startTime)
                }
                print("VOICE_ERRORS", failures)
                let branches = member(audio, "trackInputBranches") as! [ObjectIdentifier: [AVAudioMixerNode]]
                print("BRANCH_COUNTS", branches.values.map(\.count), "TRACK_BUSES", values(member(audio, "trackBuses")).count)
                for group in branches.values { for (index, branch) in group.enumerated() {
                    print("BRANCH_CONNECTIONS", index, engine.outputConnectionPoints(for: branch, outputBus: 0).map(\.bus))
                    for point in engine.outputConnectionPoints(for: branch, outputBus: 0) {
                        if let mixer = point.node as? AVAudioMixerNode {
                            print("BRANCH_STATE", index, "inputs", branch.numberOfInputs, "outputBus", point.bus,
                                  "inputGain", branch.destination(forMixer: mixer, bus: point.bus)?.volume ?? -99,
                                  "outputGain", branch.outputVolume)
                        }
                    }
                } }
                for (track, bus) in member(audio, "trackBuses") as! [UUID: Any] {
                    let send = member(bus, "masterSend") as! AVAudioMixerNode
                    print("MASTER_SEND", originals.firstIndex(where: {$0.id == track}) ?? -1, "gain", send.outputVolume,
                          "connections", engine.outputConnectionPoints(for: send, outputBus: 0).map(\.bus))
                }

            }
            require(audible == count, "all live copies must produce audio")
            inspect(count)
            if abs(audio.masterMeter.level - Double(count) * 0.004) >= Double(count) * 0.0002 {
                print("SHARED_SUM_DIAGNOSTIC", "voices", values(member(audio, "voices")).count,
                      "retired", (member(audio, "retiredVoices") as! [Any]).count,
                      "tails", values(member(audio, "effectTails")).count,
                      "levels", originals.prefix(count).map { audio.meter(for: $0.id).level })
            }
            require(abs(audio.masterMeter.level - Double(count) * 0.004) < Double(count) * 0.0002, "independent copies must sum at Master")
            require(engine.mainMixerNode.outputVolume == 0, "fixture must remain physically silent")
        }
        func verifyMaster(_ label: String, expected: Double) async throws {
            var peak = 0.0
            for frame in 0..<observationFrames {
                state.transport.position = ProcessInfo.processInfo.systemUptime - origin
                try audio.update(state, revision: revision)
                try await Task.sleep(nanoseconds: 30_000_000)
                if frame > 25 { peak = max(peak, audio.masterMeter.level) }
            }
            print("SHARED_LIVE_STATE", label, "master", peak, "expected", expected)
            require(abs(peak - expected) < max(0.0004, expected * 0.05), label + " must preserve the complete independent mix")
            require(engine.mainMixerNode.outputVolume == 0, "fixture must remain physically silent")
            inspect(targetCount)
        }
        state.project.songs[0].tracks[0].solo = true; revision += 1
        try await verifyMaster("solo", expected: 0.004)
        state.project.songs[0].tracks[0].solo = false; revision += 1
        try await verifyMaster("unsolo", expected: Double(targetCount) * 0.004)
        state.transport.playing = false; state.transport.position = 0
        try audio.update(state, revision: revision)
        if let preparation = try audio.pendingPlaybackPreparation(state, revision: revision) { await preparation.value }
        state.transport.playing = true; try audio.update(state, revision: revision)
        reportDeadline("restart")
        origin = ProcessInfo.processInfo.systemUptime
        try await verifyMaster("restart", expected: Double(targetCount) * 0.004)
    } else {
        state.transport.playing = true; try audio.update(state, revision: revision)
        // Exercise the live prepared-source graph with a manually driven
        // sample clock. Wall-clock scheduling is covered by --hardware below.
        for voice in values(member(audio, "voices")) {
            let source = Mirror(reflecting: member(voice, "prepared")).children.first!.value as! JarasPreparedClip
            source.start(atHostTime: 0, ramp: false)
            JarasVoiceGain.setStartHostTime(member(voice, "gain") as! AVAudioUnitEffect, hostTime: 0)
        }
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        var peak: Float = 0
        for block in 0..<256 {
            require(try engine.renderOffline(512, to: out) == .success, "offline rendering")
            if block > 32 { for frame in 0..<512 { peak = max(peak, abs(out.floatChannelData![0][frame])) } }
        }
        print("SHARED_OFFLINE_MP3_SUM", targetCount, peak)
        require(abs(peak - Float(targetCount) * 0.004) < Float(targetCount) * 0.0002, "independent copies must sum through the actual graph")
        inspect(targetCount)
    }
    print("SHARED_FILE_VOICES_OK", hardware ? "hardware" : "offline", "descriptorLimit", low.rlim_cur)
}
Task { @MainActor in
    do { try await run(hardware: CommandLine.arguments.contains("--hardware")); exit(0) }
    catch { print("SHARED_VOICES_ERROR", error); exit(1) }
}
dispatchMain()
