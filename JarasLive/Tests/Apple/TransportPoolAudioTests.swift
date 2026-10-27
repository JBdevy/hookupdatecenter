import Foundation
import AVFoundation
import Darwin

// Requires a live macOS audio device. The hardware output is muted; taps still
// inspect the PCM before that mute. Run through scripts/test-audio.sh with
// JARAS_AUDIO_TEST_SOURCE=Tests/Apple/TransportPoolAudioTests.swift.
setbuf(stdout, nil)
UserDefaults.standard.setVolatileDomain(["jaras.metronome.enabled": false], forName: UserDefaults.argumentDomain)

private struct PoolTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw PoolTestFailure(description: message) }
}

private func hostSeconds(_ host: UInt64, after origin: UInt64) -> Double {
    host >= origin ? AVAudioTime.seconds(forHostTime: host - origin)
        : -AVAudioTime.seconds(forHostTime: origin - host)
}

private final class PoolCapture: @unchecked Sendable {
    struct Block {
        let host: UInt64
        let rate: Double
        let channels: [[Float]]
    }
    struct Frame {
        let seconds: Double
        let values: [Float]
        var peak: Float { values.map(abs).max() ?? 0 }
    }
    private let lock = NSLock()
    private var blocks: [Block] = []

    func append(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
        guard time.isHostTimeValid, let channels = buffer.floatChannelData else { return }
        let copied = (0..<min(2, Int(buffer.format.channelCount))).map {
            Array(UnsafeBufferPointer(start: channels[$0], count: Int(buffer.frameLength)))
        }
        lock.lock()
        blocks.append(Block(host: time.hostTime, rate: buffer.format.sampleRate, channels: copied))
        lock.unlock()
    }

    @discardableResult func clear() -> UInt64 {
        lock.lock()
        blocks.removeAll(keepingCapacity: true)
        let now = mach_absolute_time()
        lock.unlock()
        return now
    }

    func frames(after origin: UInt64) -> [Frame] {
        lock.lock()
        let snapshot = blocks
        lock.unlock()
        return snapshot.flatMap { block -> [Frame] in
            guard let count = block.channels.first?.count else { return [] }
            let start = hostSeconds(block.host, after: origin)
            return (0..<count).compactMap { index in
                let seconds = start + Double(index) / block.rate
                guard seconds >= 0 else { return nil }
                return Frame(seconds: seconds, values: block.channels.map { $0[index] })
            }
        }
    }
}

private func property(_ name: String, of value: Any) -> Any {
    guard let result = Mirror(reflecting: value).children.first(where: { $0.label == name })?.value else {
        preconditionFailure("Missing diagnostic property: \(name)")
    }
    return result
}

private func dictionaryValues(_ dictionary: Any) -> [Any] {
    Mirror(reflecting: dictionary).children.map { property("value", of: $0.value) }
}

@MainActor private func activePlayers(_ audio: StemAudioPlayback) -> Set<ObjectIdentifier> {
    Set(dictionaryValues(property("voices", of: audio)).map {
        ObjectIdentifier(property("player", of: $0) as! AVAudioPlayerNode)
    })
}

@MainActor private func pooledPlayers(_ audio: StemAudioPlayback) -> Set<ObjectIdentifier> {
    Set(dictionaryValues(property("idleVoices", of: audio)).flatMap { pool in
        Mirror(reflecting: pool).children.map {
            ObjectIdentifier(property("player", of: $0.value) as! AVAudioPlayerNode)
        }
    })
}

@MainActor private func runTransportPoolTest() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("transport-pool-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // Alternating source formats exercises the format converters that used to
    // retain old PCM across Stop. A sign change distinguishes a stale old onset
    // from the new seek's samples. Both seeks avoid the sign change itself.
    for rate in [44100.0, 48000.0] {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 2.4))!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            for sample in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![channel][sample] = Double(sample) < rate * 0.75 ? 0.01 : -0.01
            }
        }
        let file = try AVAudioFile(forWriting: directory.appendingPathComponent("source-\(Int(rate)).wav"), settings: format.settings)
        try file.write(from: buffer)
    }

    let engine = AVAudioEngine()
    let audio = StemAudioPlayback(engine: engine, realtime: true)
    audio.open(directory: directory)
    defer { audio.prepareForClosing() }
    var project = Project.empty(name: "Mixed-rate transport pool")
    var tracks: [Track] = []
    let firstRate = ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] == "48000" ? 48000 : 44100
    for index in 0..<24 {
        let rate = index.isMultiple(of: 2) ? firstRate : (firstRate == 44100 ? 48000 : 44100)
        var track = Track(id: UUID(), name: "Track \(index + 1)", role: .other)
        track.clips = [AudioClip(id: UUID(), name: "Constant \(rate)", startTime: 0, duration: 2.4,
            audioFile: AudioFile(path: "source-\(rate).wav"))]
        if index == 0 {
            // A real populated insert chain must survive Stop as well as the
            // sources. Its tail must not escape the final output router.
            var effects = NativeFXSettings()
            effects.inserted = ["Delay"]
            effects.delayEnabled = true
            effects.delayMix = 20
            effects.feedback = 20
            effects.delayTime = 0.03
            track.fx = effects
        }
        tracks.append(track)
    }
    project.songs[0].tracks = tracks
    project.songs[0].duration = 2.4
    var snapshot = ShowSnapshot(project: project, transport: TransportState(playing: false,
        songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false),
        subPlay: SubPlayState(playing: false, position: 0)))
    try audio.update(snapshot, revision: 1)
    engine.mainMixerNode.outputVolume = 0
    // Real projects prepare their first sources while stopped. Exercise the
    // first Play after that idle preparation, not only subsequent replay.
    try await Task.sleep(nanoseconds: 1_500_000_000)
    let initiallyPrepared = pooledPlayers(audio)

    let master = property("masterBus", of: audio) as! AVAudioMixerNode
    let router = (property("masterRoutes", of: audio) as! [AVAudioUnitEffect])[0]
    let onsetCapture = PoolCapture(), outputCapture = PoolCapture()
    master.installTap(onBus: 0, bufferSize: 128, format: nil) { onsetCapture.append($0, $1) }
    router.installTap(onBus: 0, bufferSize: 128, format: nil) { outputCapture.append($0, $1) }
    defer {
        master.removeTap(onBus: 0)
        router.removeTap(onBus: 0)
    }

    // Warm all sources and the FX once. Identity assertions below do not depend
    // on machine speed, asynchronous prefetch duration, or a latency threshold.
    snapshot.transport.playing = true
    try audio.update(snapshot, revision: 1)
    try await Task.sleep(nanoseconds: 350_000_000)
    let nodes = engine.attachedNodes
    let players = activePlayers(audio)
    try require(players.count == 24, "The warmup must exercise all 24 sources")
    try require(initiallyPrepared.count == 24 && initiallyPrepared == players,
        "First Play replaced players that had already been prepared while stopped")
    let deviceRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
    print("TRANSPORT_POOL_WARM tracks=24 firstSourceRate=\(firstRate) deviceRate=\(deviceRate) nodes=\(nodes.count)")

    // Compare the scheduling snapshot with AVAudioEngine's authoritative
    // latency values across source converters, nested FX and mixer fan-outs.
    // Timings are diagnostic only; correctness must not depend on machine speed.
    let measuredNodes = engine.attachedNodes.filter {
        $0 is AVAudioPlayerNode || $0 is AVAudioUnitTimePitch || $0 is AVAudioMixerNode
    }
    let graphLatencies = AudioGraphLatencySnapshot(engine: engine)
    let graphBegin = mach_absolute_time()
    let calculated = measuredNodes.map { ($0, graphLatencies.presentationLatency(for: $0)) }
    let graphMS = hostSeconds(mach_absolute_time(), after: graphBegin) * 1000
    let nativeBegin = mach_absolute_time()
    for (node, value) in calculated {
        try require(abs(value - node.outputPresentationLatency) < 0.000001,
            "Scheduling latency differs from AVAudioEngine for \(type(of: node))")
    }
    print("TRANSPORT_GRAPH_LATENCY nodes=\(measuredNodes.count) snapshotMS=\(graphMS) nativeMS=\(hostSeconds(mach_absolute_time(), after: nativeBegin) * 1000)")

    // Include immediate Stop→Play, which a 150 ms pause alone can conceal by
    // allowing stale converter PCM to drain before the next scheduling call.
    let scenarios: [(position: Double, idleNS: UInt64)] = [
        (0, 150_000_000), (1, 150_000_000), (0, 0), (1, 0), (0, 300_000_000), (1, 0),
        (0, 2_000_000_000), (1, 2_000_000_000), (0, 10_000_000_000)
    ]
    let hardwareBufferSeconds = Double(AudioDeviceSettings.shared.bufferFrames) / max(1, deviceRate)
    let routerFadeSeconds = max(0.005, 64 / max(1, deviceRate))
    var measuredStopDrainSeconds = 0.0
    for (iteration, scenario) in scenarios.enumerated() {
        let stopBegin = outputCapture.clear()
        snapshot.transport.playing = false
        snapshot.transport.position = scenario.position
        try audio.update(snapshot, revision: 1)
        let stopComplete = mach_absolute_time()
        let stopRenderHost = engine.outputNode.lastRenderTime?.hostTime ?? stopComplete
        let stopMS = hostSeconds(stopComplete, after: stopBegin) * 1000
        print("TRANSPORT_POOL_STOP iteration=\(iteration) stopMS=\(stopMS) nodes=\(engine.attachedNodes.count) pooledPlayers=\(pooledPlayers(audio).count)")
        try require(engine.attachedNodes == nodes, "Stop detached or created engine nodes, iteration \(iteration)")
        try require(pooledPlayers(audio) == players, "Stop did not retain every warmed player, iteration \(iteration)")
        var stopLastSoundMS = -1.0
        if scenario.idleNS > 0 {
            try await Task.sleep(nanoseconds: scenario.idleNS)
            let stopped = outputCapture.frames(after: stopBegin)
            stopLastSoundMS = (stopped.last(where: { $0.peak > 0.00001 })?.seconds ?? -0.001) * 1000
            measuredStopDrainSeconds = max(measuredStopDrainSeconds, (stopLastSoundMS - stopMS) / 1000)
            // Measure at the router, after its intentional short Stop fade.
            // Only demand settled silence; report the actual audible stop time.
            let end = stopped.last?.seconds ?? 0
            let settled = stopped.filter { $0.seconds >= max(0.08, end - 0.04) }
            try require(!settled.isEmpty, "No live output samples captured after Stop")
            if settled.contains(where: { $0.peak >= 0.00001 }) {
                print("STOP_CAPTURE_FAILURE", "iteration", iteration, "stopMS", stopMS, "lastSoundMS", stopLastSoundMS,
                      "capturedEndMS", end * 1000, "settledPeak", settled.map(\.peak).max() ?? 0)
            }
            try require(settled.allSatisfy { $0.peak < 0.00001 }, "Stop left audio or FX tails at the output")
            try require(engine.attachedNodes == nodes, "Idle preparation replaced warmed nodes")
        }

        let playBegin = onsetCapture.clear()
        // A same-turn Play can start capturing in the middle of audio that HAL
        // already rendered for the preceding Stop. Bound that old tail using
        // the render head plus one hardware block and the router's 5 ms fade.
        // Measured isolated Stops account for the device's queued output; one
        // block covers a different phase of its callback. This never excludes
        // any samples at or after the new scheduled onset.
        let oldTailEnd = max(stopComplete, stopRenderHost) + AVAudioTime.hostTime(forSeconds:
            hardwareBufferSeconds + max(routerFadeSeconds, measuredStopDrainSeconds))
        let oldTailSeconds = max(0, hostSeconds(oldTailEnd, after: playBegin))
        snapshot.transport.playing = true
        try audio.update(snapshot, revision: 1)
        let playMS = hostSeconds(mach_absolute_time(), after: playBegin) * 1000
        print("TRANSPORT_POOL_PLAY iteration=\(iteration) playMS=\(playMS) nodes=\(engine.attachedNodes.count) activePlayers=\(activePlayers(audio).count)")
        try require(engine.attachedNodes == nodes, "Play rebuilt the warmed graph, iteration \(iteration)")
        try require(activePlayers(audio) == players, "Play replaced a warmed player, iteration \(iteration)")
        let clocks = property("headAudioClock", of: audio) as! [Int: (position: Double, host: UInt64)]
        guard let clock = clocks[0] else { throw PoolTestFailure(description: "Play did not publish its audible deadline") }
        let boundary = hostSeconds(clock.host, after: playBegin)
        // Taps may deliver ~100 ms chunks. Collect enough PCM past the onset
        // and settling interval even when hardware presentation is delayed.
        try await Task.sleep(nanoseconds: 500_000_000)
        let frames = onsetCapture.frames(after: playBegin)
        try require(!frames.isEmpty, "Play produced no tap callbacks")
        let peak = frames.map(\.peak).max() ?? 0
        let firstSound = frames.first(where: { $0.seconds >= min(oldTailSeconds, boundary) && $0.peak > 0.001 })?.seconds ?? -1
        // SRC filters may pre-ring briefly. The continuously warmed sources
        // must nevertheless follow the device clock after a long idle, without
        // the accumulated player timestamp drift seen at mixed sample rates.
        let onsetTolerance = 0.001
        let beforeOnset = frames.filter { $0.seconds >= oldTailSeconds && $0.seconds < boundary - onsetTolerance }
        let filterEdge = frames.filter { $0.seconds >= max(oldTailSeconds, boundary - onsetTolerance) && $0.seconds < boundary }
        let expectedSign: Float = scenario.position == 0 ? 1 : -1
        print("TRANSPORT_POOL_FILTER_EDGE peak=\(filterEdge.map(\.peak).max() ?? 0) boundaryMS=\(boundary * 1000) firstSoundMS=\(firstSound * 1000)")
        try require((filterEdge.map(\.peak).max() ?? 0) < 0.002, "Old PCM escaped at the resampler onset edge")
        try require(filterEdge.allSatisfy { $0.values.allSatisfy { $0 * expectedSign >= -0.0001 } },
            "Old source PCM escaped at the resampler onset edge")
        let earlyPeak = beforeOnset.map(\.peak).max() ?? 0
        if let early = beforeOnset.max(by: { $0.peak < $1.peak }) {
            print("TRANSPORT_POOL_EARLY peak=\(early.peak) afterBoundaryMS=\((early.seconds-boundary)*1000)")
        }
        // The master tap is upstream of the output router's Stop fade. Its
        // clearing sources are intentionally masked by that fade; measure the
        // new Play after the bounded old tail, comparing actual neighbors.
        var previous = frames[0].values, maxStep: Float = 0
        var maxStepIndex = 0, maxStepChannel = 0
        for index in frames.indices.dropFirst() {
            let frame = frames[index]
            for channel in frame.values.indices {
                let step = abs(frame.values[channel] - previous[channel])
                if frames[index - 1].seconds >= oldTailSeconds && step > maxStep {
                    maxStep = step
                    maxStepIndex = index
                    maxStepChannel = channel
                }
                previous[channel] = frame.values[channel]
            }
        }
        let settled = frames.filter { $0.seconds > boundary + 0.15 }
        let sign: Float = scenario.position == 0 ? 1 : -1
        print("TRANSPORT_POOL iteration=\(iteration) position=\(scenario.position) idleMS=\(Double(scenario.idleNS) / 1e6) playMS=\(playMS) stopMS=\(stopMS) firstSoundMS=\(firstSound * 1000) scheduledMS=\(boundary * 1000) stopLastSoundMS=\(stopLastSoundMS) peak=\(peak) earlyPeak=\(earlyPeak) maxStep=\(maxStep)")
        print("TRANSPORT_POOL_STOP_BOUNDARY iteration=\(iteration) renderHeadAfterStopMS=\(hostSeconds(stopRenderHost, after: stopComplete) * 1000) measuredDrainMS=\(measuredStopDrainSeconds * 1000) allowedOldTailAfterPlayMS=\(oldTailSeconds * 1000) checkedSilentFrames=\(beforeOnset.count)")
        let largest = frames[maxStepIndex]
        let preceding = maxStepIndex > 0 ? frames[maxStepIndex - 1] : nil
        let timestampGapSamples = preceding.map { (largest.seconds - $0.seconds) * deviceRate } ?? -1
        print("TRANSPORT_POOL_MAX_STEP iteration=\(iteration) index=\(maxStepIndex) channel=\(maxStepChannel) afterPlayMS=\(largest.seconds * 1000) afterBoundaryMS=\((largest.seconds - boundary) * 1000) timestampGapSamples=\(timestampGapSamples)")
        if maxStep >= 0.005 {
            for index in max(0, maxStepIndex - 6)..<min(frames.count, maxStepIndex + 9) {
                let frame = frames[index]
                print("TRANSPORT_POOL_SAMPLE index=\(index) afterBoundaryMS=\((frame.seconds - boundary) * 1000) values=\(frame.values)")
            }
        }
        try require(peak > 0.2, "One or more sources failed to resume")
        try require(earlyPeak < 0.0001, "Old converter PCM escaped before the scheduled onset")
        try require(maxStep < 0.005, "Play introduced an abrupt PCM discontinuity")
        try require(!settled.isEmpty && settled.allSatisfy { $0.values.allSatisfy { $0 * sign > 0.2 } },
            "Playback resumed old source samples instead of the requested position")
        try require(engine.attachedNodes == nodes, "Playback asynchronously rebuilt the warmed graph")
    }
    print("TRANSPORT_POOL_MIXED_RATE_STOP_REPLAY_IDENTITY_AND_PCM_OK")
}

Task { @MainActor in
    do { try await runTransportPoolTest(); exit(0) }
    catch { print("TRANSPORT_POOL_FAILED: \(error)"); exit(1) }
}
dispatchMain()
