import Foundation
import AVFoundation
import Darwin

setbuf(stdout, nil)

private func require(_ condition: Bool, _ message: String = "Idle audio assertion failed") {
    precondition(condition, message)
}

private final class RenderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var amplitude: Float = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func set(_ value: Float) { lock.lock(); amplitude = value; lock.unlock() }
    func node(_ format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { [self] silent, _, frames, buffers in
            lock.lock(); count += 1; let value = amplitude; lock.unlock()
            silent.pointee = ObjCBool(value == 0)
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                buffer.mData!.assumingMemoryBound(to: Float.self).update(repeating: value, count: Int(frames))
            }
            return noErr
        }
    }
}

@MainActor private func graphEnabled(_ audio: StemAudioPlayback) -> Bool {
    Mirror(reflecting: audio).children.first { $0.label == "renderEnabled" }!.value as! Bool
}

@MainActor private func testIdlePolicies() async throws {
    let rate = 48000.0
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let audio = StemAudioPlayback(engine: engine, realtime: true)
    audio.open(directory: FileManager.default.temporaryDirectory)
    defer { audio.prepareForClosing() }
    var project = Project.empty(name: "Isolated idle guards")
    let instrument = Track(id: UUID(), name: "Instrument probe", role: .keys)
    let input = Track(id: UUID(), name: "Input", role: .other)
    var pad = Track(id: UUID(), name: "Pads", role: TrackRole(rawValue: "vinhetas"))
    var delay = NativeFXSettings(); delay.appendNative("Delay")
    delay.delayTime = 0.08; delay.feedback = 30; delay.delayMix = 100
    pad.fx = delay
    project.songs[0].tracks = [instrument, input, pad]
    let state = ShowSnapshot(project: project, transport: TransportState(playing: false,
        songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false),
        subPlay: SubPlayState(playing: false, position: 0)))
    try audio.update(state, revision: 1)
    let probe = RenderProbe(), source = probe.node(format)
    engine.attach(source)
    let instrumentInput = audio.effects(for: instrument.id)!.instrumentInput
    engine.connect(source, to: instrumentInput, format: format)
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    func render(_ blocks: Int) throws -> Float {
        var peak: Float = 0
        for _ in 0..<blocks {
            require(try engine.renderOffline(512, to: output) == .success)
            for channel in 0..<2 { for frame in 0..<512 {
                peak = max(peak, abs(output.floatChannelData![channel][frame]))
            } }
        }
        return peak
    }
    let nodes = Set(engine.attachedNodes.map(ObjectIdentifier.init))
    _ = try render(20)
    require(!graphEnabled(audio) && probe.calls == 0 && engine.isRunning,
                 "Cold idle must stop upstream pulls while the device stays running")

    probe.set(0.03125)
    audio.setArmedInstrumentTracks([instrument.id])
    require(try render(10) > 0.03 && probe.calls > 0, "Armed instrument must render with stopped transport")
    audio.setArmedInstrumentTracks([])
    require(try render(10) > 0.03 && graphEnabled(audio), "Disarming must preserve held notes/plugin tails until Stop")
    audio.stop()
    _ = try render(10)
    let stoppedCalls = probe.calls
    require(try render(20) == 0 && probe.calls == stoppedCalls && !graphEnabled(audio))
    require(Set(engine.attachedNodes.map(ObjectIdentifier.init)) == nodes && engine.isRunning,
                 "Idle must retain graph nodes and the running output device")
    probe.set(0)

    let monitorProbe = RenderProbe(); monitorProbe.set(0.0625)
    audio.setInputMonitor(input.id, source: monitorProbe.node(format), format: format)
    require(try render(10) > 0.06, "Input monitoring must wake an idle graph")
    audio.stop()
    _ = try render(4)
    require(try render(10) > 0.06 && graphEnabled(audio), "Stop must preserve an attached input monitor")
    audio.setInputMonitor(input.id, source: nil)
    require(graphEnabled(audio), "Removing live input must preserve unknown effect tails until Stop")
    audio.stop(); _ = try render(10)
    require(!graphEnabled(audio))

    let ring = JarasCaptureRing(channels: 2, capacity: 65536); ring.beginCapture()
    _ = try audio.attachOutputCapture(instrument.id, postFX: true, postFader: true, ring: ring)
    let beforeCapture = probe.calls
    for _ in 0..<12 { _ = try render(1); try await Task.sleep(nanoseconds: 2_000_000) }
    require(graphEnabled(audio) && probe.calls > beforeCapture, "An output capture must pull its source while stopped")
    var captured = [Float](repeating: 0, count: 131072)
    let frames = captured.withUnsafeMutableBufferPointer { ring.readFrames($0.baseAddress!, maximum: 65536) }
    require(frames > 512, "The stopped output capture must deliver PCM")
    audio.stop(); require(graphEnabled(audio), "Stop must preserve an attached recording tap")
    audio.detachOutputCapture(instrument.id)
    require(!graphEnabled(audio), "Detaching the last capture must restore idle without a graph rebuild")

    let pulse = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240)!
    pulse.frameLength = 240
    for channel in 0..<2 { pulse.floatChannelData![channel].update(repeating: 0.125, count: 240) }
    let voice = UUID()
    try audio.playPad(voice, buffer: pulse, gain: 1, track: pad.id, finished: {})
    _ = try render(2); audio.finishReleasedPads()
    require(graphEnabled(audio), "Natural pad completion must preserve its delay tail")
    let tail = try render(30)
    require(tail > 0.02, "Pad delay was truncated after its source ended: \(tail)")
    audio.stop(); _ = try render(10)
    let afterStop = probe.calls
    require(try render(20) == 0 && !graphEnabled(audio) && probe.calls == afterStop,
                 "Explicit Stop must clear live-tail latches and return to idle")
    print("IDLE_GRAPH_NO_UPSTREAM_PULLS_DEVICE_RETAINED_INSTRUMENT_MONITOR_CAPTURE_PAD_TAIL_AND_STOP_OK")
    if let path = ProcessInfo.processInfo.environment["JARAS_TEST_VST3"] {
        var error: NSError?
        let description = JarasVST3.scan(path, error: &error)[0]
        // Deliberately leave category empty: effect plugins can generate audio
        // from their own editor/clock just like instrument plugins can.
        let plugin = ExternalPlugin(classID: description["classID"] as! String, name: "Independent generator", path: path)
        var fx = NativeFXSettings(); fx.externalPlugins = [plugin]; fx.inserted = [plugin.effectKey]
        for master in [false, true] {
            var externalState = state
            if master { externalState.project.masterFX = fx }
            else { externalState.project.songs[0].tracks[0].fx = fx }
            try audio.update(externalState, revision: master ? 3 : 2)
            audio.stop()
            require(graphEnabled(audio), "Unarmed external processors must retain their existing render clock")
            let node = audio.effects(for: master ? nil : instrument.id)!.externalNode(plugin.id)!
            JarasVST3.sendMIDI(node, status: 0x90, data1: 60, data2: 100)
            require(try render(20) > 0.05, "The external editor/generator must sound without transport or REC")
        }
        print("IDLE_EXTERNAL_TRACK_AND_MASTER_GENERATORS_WITHOUT_REC_PRESERVED_OK")
    }
}

@MainActor private func testFirstPCM() async throws {
    // Real hardware timestamps reproduce stale converter epochs. Mute only the
    // final output; pre-output route peaks still prove when the PCM arrives.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-idle-first-pcm-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let legacy = CommandLine.arguments.contains("--legacy")
    if legacy { setenv("CATLIVE_PREPARED_SOURCE", "0", 1) }
    // One hardware engine per process avoids AVFAudio's asynchronous clock
    // teardown overlapping the next fixture's output unit creation.
    for rate in [Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!] {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 3))!
        pcm.frameLength = pcm.frameCapacity
        for channel in 0..<2 { pcm.floatChannelData![channel].update(repeating: 0.04, count: Int(pcm.frameLength)) }
        let path = "tone-\(Int(rate)).wav"
        try AVAudioFile(forWriting: folder.appendingPathComponent(path), settings: format.settings).write(from: pcm)
        let engine = AVAudioEngine()
        let audio = StemAudioPlayback(engine: engine, auxiliarySelectedHardware: true)
        audio.setLicenseAllowed(false)
        try audio.startDeviceSession(); audio.open(directory: folder)
        defer { audio.prepareForClosing() }
        var project = Project.empty(name: "Idle first PCM")
        var group = Track(id: UUID(), name: "Group", role: .other); group.volume = 0.5
        var original = Track(id: UUID(), name: "Original", role: .other); original.parentTrackID = group.id
        original.clips = [AudioClip(id: UUID(), name: "Tone", startTime: 0, duration: 3, audioFile: AudioFile(path: path))]
        var copy = original; copy.id = UUID(); copy.clips[0].id = UUID()
        project.songs[0].tracks = [group, original, copy] + (0..<32).map { Track(id: UUID(), name: "Idle \($0)", role: .other) }
        project.songs[0].duration = 3
        var state = ShowSnapshot(project: project, transport: TransportState(playing: false,
            songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false),
            subPlay: SubPlayState(playing: false, position: 0)))
        try audio.update(state, revision: 1)
        let routes = Mirror(reflecting: audio).children.first { $0.label == "masterRoutes" }!.value as! [AVAudioUnitEffect]
        let route = routes[0]
        for idle in [0.25, 1.0, 2.0] {
            try await Task.sleep(nanoseconds: UInt64(idle * 1_000_000_000))
            require(graphEnabled(audio) == legacy && engine.isRunning && engine.mainMixerNode.outputVolume == 0,
                    "Prepared sources must idle; legacy player clocks must stay warm")
            let before = Set(engine.attachedNodes.map(ObjectIdentifier.init))
            _ = JarasChannelRouter.takeInputPeak(route, channel: 0)
            state.transport.playing = true; state.transport.position = 0
            let started = ProcessInfo.processInfo.systemUptime
            try audio.update(state, revision: 1, sampledAt: started)
            var first: Double?, peak: Float = 0
            while ProcessInfo.processInfo.systemUptime - started < 0.5 {
                try await Task.sleep(nanoseconds: 2_000_000)
                peak = max(peak, JarasChannelRouter.takeInputPeak(route, channel: 0))
                if first == nil && peak > 0.01 { first = ProcessInfo.processInfo.systemUptime - started }
                if peak > 0.039 { break }
            }
            require(first != nil && first! < 0.20,
                         "First PCM delayed after \(idle)s idle at \(rate) Hz: \(String(describing: first))")
            require(peak > 0.039 && peak < 0.041, "Copied group tracks must each reach the group/master exactly once: \(peak)")
            require(Set(engine.attachedNodes.map(ObjectIdentifier.init)) == before,
                         "Play after idle must reuse prepared nodes")
            print("IDLE_FIRST_PCM legacy=\(legacy) rate=\(Int(rate)) idle=\(idle) first_ms=\(first! * 1000) peak=\(peak)")
            state.transport.playing = false
            audio.stop()
            try audio.update(state, revision: 1)
        }
        print("IDLE_REAL_HARDWARE_FIRST_PCM_AND_COPIED_GROUP_OK rate=\(Int(rate))")
    }
}

Task { @MainActor in
    do {
        UserDefaults.standard.setVolatileDomain(["jaras.metronome.enabled": false], forName: UserDefaults.argumentDomain)
        try await testIdlePolicies()
        try await testFirstPCM()
        exit(0)
    } catch { print("IDLE_AUDIO_GRAPH_ERROR", error); exit(1) }
}
dispatchMain()
