import AVFoundation
import Foundation

let asset = URL(fileURLWithPath: CommandLine.arguments[1])
for rate in [44100.0, 48000.0] {
    let sound = try ClickAudioSample.load(sampleRate: rate, url: asset)
    precondition(sound.count > Int(rate * 0.1) * 4 && sound.count < Int(rate * 1.6) * 4)
    let engine = AVAudioEngine()
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let bus = AVAudioMixerNode(); engine.attach(bus)
    let generators = (0..<2).map { _ in JarasMetronomeGenerator(format: format) }
    for (index, generator) in generators.enumerated() {
        engine.attach(generator.node)
        engine.connect(generator.node, to: bus, fromBus: 0, toBus: AVAudioNodeBus(index), format: format)
        generator.setClickSections([["start": 0.25, "end": 1.9, "origin": 0.25, "bpm": 120, "beats": 4, "unit": 4]], sound: sound)
    }
    engine.connect(bus, to: engine.mainMixerNode, format: format)
    engine.prepare(); try engine.start()
    defer { engine.stop() }
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    func capture(seconds: Double) throws -> [Float] {
        var samples: [Float] = []
        while samples.count < Int(seconds * rate) {
            let count = AVAudioFrameCount(min(512, Int(seconds * rate) - samples.count))
            let status = try engine.renderOffline(count, to: buffer)
            precondition(status == .success)
            samples += Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        return samples
    }
    func start(_ generator: JarasMetronomeGenerator, position: Double = 0) {
        generator.configurePosition(position, hostTime: mach_absolute_time(), running: true, loopStart: 0, loopEnd: 0, sampleTime: Double(engine.manualRenderingSampleTime))
    }
    func stop(_ generator: JarasMetronomeGenerator) {
        generator.configurePosition(0, hostTime: mach_absolute_time(), running: false, loopStart: 0, loopEnd: 0, sampleTime: Double(engine.manualRenderingSampleTime))
    }
    start(generators[0])
    let normal = try capture(seconds: 2.1)
    let peak = normal.map { abs($0) }.max()!
    precondition(peak > 0.1, "Bundled MP3 must reach the output")
    precondition(normal[0..<Int(rate * 0.25)].allSatisfy { $0 == 0 })
    precondition(normal[Int(rate * 1.9)...].allSatisfy { $0 == 0 }, "Item edge truncates the one-shot")
    stop(generators[0]); _ = try capture(seconds: 0.02)
    bus.outputVolume = 0.5
    start(generators[1]) // the second head plays independently
    let half = try capture(seconds: 2.1)
    precondition(abs(half.map { abs($0) }.max()! / peak - 0.5) < 0.002, "Track fader controls Sub Play")
    stop(generators[1]); _ = try capture(seconds: 0.02)
    bus.outputVolume = 0
    start(generators[0]); start(generators[1])
    let muted = try capture(seconds: 1)
    precondition(muted.allSatisfy { abs($0) < 0.000001 }, "Track mute gates both heads")
    stop(generators[0]); stop(generators[1]); bus.outputVolume = 1
    _ = try capture(seconds: 0.02)
    let stopped = try capture(seconds: 0.6)
    precondition(stopped.allSatisfy { $0 == 0 })
    // Short probe pulses measure beat spacing without overlapping sample tails.
    let pulse = [Float](repeating: 0.5, count: 64).withUnsafeBytes { Data($0) }
    generators[0].setClickSections([
        ["start": 0, "end": 1, "origin": 0, "bpm": 240, "beats": 8, "unit": 4],
        ["start": 1, "end": 2, "origin": 0, "bpm": 120, "beats": 4, "unit": 4]
    ], sound: pulse)
    start(generators[0])
    let divided = try capture(seconds: 2)
    func energy(_ at: Double) -> Float { divided[Int(at * rate)..<Int(at * rate) + 128].reduce(0) { $0 + abs($1) } }
    precondition(energy(0.25) > 1 && energy(0.75) > 1, "2x must play the subdivisions")
    precondition(energy(1.25) == 0 && energy(1.5) > 1, "The next 1x item must retain its own spacing")
    stop(generators[0])
    // The synthesized click uses the same per-item Subplay selection as audio.
    var clickSong = Project.empty(name: "Click membership").songs[0]
    clickSong.bpm = 120; clickSong.duration = 6; clickSong.regionOwnershipInitialized = true
    let previousRegion = Part(id: UUID(), name: "Previous", startTime: 0, endTime: 4)
    let incomingRegion = Part(id: UUID(), name: "Incoming", startTime: 2, endTime: 6)
    clickSong.parts = [previousRegion, incomingRegion]
    var selectedClick = Track(id: UUID(), name: "Click", role: TrackRole(rawValue: "generatedClick"))
    var previousClick = AudioClip(id: Project.clickItemID(previousRegion.id), name: "Previous", startTime: 0, duration: 4)
    previousClick.regionOwnerID = previousRegion.id; previousClick.clickDouble = true
    var incomingClick = AudioClip(id: Project.clickItemID(incomingRegion.id), name: "Incoming", startTime: 2, duration: 4)
    incomingClick.regionOwnerID = incomingRegion.id
    selectedClick.clips = [previousClick, incomingClick]; clickSong.tracks = [selectedClick]
    var clickTransport = TransportState(playing: true, songId: clickSong.id, position: 2,
        queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: true, position: 2))
    clickTransport.subExclusivePlaybackRegionId = incomingRegion.id
    func applyClickScope() {
        for head in 0..<2 {
            let sections = ClickTrackProgram.sections(song: clickSong, track: selectedClick, transport: clickTransport,
                head: head, selectedTracks: [selectedClick.id])
            generators[head].setClickSections(sections.map {
                ["start": $0.start, "end": $0.end, "origin": $0.origin, "bpm": $0.bpm, "beats": Double($0.beats), "unit": Double($0.unit)]
            }, sound: pulse)
            if head == 0 || clickTransport.subPlay.playing { start(generators[head], position: 2) }
            else { stop(generators[head]) }
        }
    }
    func checkIncomingPCM(_ pcm: [Float], _ stage: String) {
        let intermediate = pcm[Int(0.25 * rate)..<Int(0.25 * rate) + 128].reduce(0) { $0 + abs($1) }
        let beat = pcm[Int(0.5 * rate)..<Int(0.5 * rate) + 128].reduce(0) { $0 + abs($1) }
        precondition(intermediate == 0 && beat > 1, "\(stage): only incoming 1x pulses, without previous 2x bleed")
        precondition((pcm.map(abs).max() ?? 0) <= 0.501, "\(stage): outgoing and incoming generators cannot double the level")
    }
    applyClickScope(); checkIncomingPCM(try capture(seconds: 0.75), "Subplay")
    clickTransport.subPlay.playing = false; clickTransport.subExclusivePlaybackRegionId = nil
    clickTransport.exclusivePlaybackRegionId = incomingRegion.id
    applyClickScope(); checkIncomingPCM(try capture(seconds: 0.75), "Promoted Play")
    stop(generators[0]); stop(generators[1])
    print("CLICK_BUNDLED_AUDIO_OK \(Int(rate)) Hz: MP3, item edges, two heads, track gain/mute, stop, exclusive Subplay and promoted membership")
}
