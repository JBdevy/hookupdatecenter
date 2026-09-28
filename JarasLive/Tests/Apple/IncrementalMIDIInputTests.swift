import Foundation
import AVFoundation

@MainActor func run() async throws {
    let fixture = URL(fileURLWithPath: ProcessInfo.processInfo.environment["JARAS_TEST_SF2"]!)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    do {
        let file = try AVAudioFile(forWriting: directory.appendingPathComponent("silent.wav"), settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 10))!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0, count: Int(buffer.frameLength)) }
        try file.write(from: buffer)
    }
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let renderer = StemAudioPlayback(engine: engine, realtime: false)
    renderer.instrumentFile = { _ in (fixture, false) }
    renderer.open(directory: directory)
    var project = Project.empty(name: "Incremental MIDI input PCM")
    var parameters = InstrumentParameters()
    parameters.attack = 0; parameters.hold = 20; parameters.decay = 20
    parameters.sustain = 1; parameters.release = 0.01
    parameters.controllers = InstrumentControllerParameters(modulation: false, pitchBend: false)
    var fx = NativeFXSettings(); fx.inserted = ["Instruments"]; fx.instrumentID = "gemani-pad"; fx.instrumentParameters = parameters
    func instrumentTrack(_ name: String, pan: Double) -> Track {
        var track = Track(id: UUID(), name: name, role: .keys)
        track.fx = fx; track.midiInput = 1; track.pan = pan
        track.clips = [AudioClip(id: UUID(), name: "Scheduled silent voice", startTime: 0, duration: 10, audioFile: AudioFile(path: "silent.wav"))]
        return track
    }
    let left = instrumentTrack("Changed instrument", pan: -1)
    let right = instrumentTrack("Continuing instrument", pan: 1)
    project.songs[0].tracks = [left, right]
    var snapshot = ShowSnapshot(project: project, transport: TransportState(playing: false, songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    try renderer.update(snapshot, revision: 1)
    for _ in 0..<200 {
        if renderer.isInstrumentReady(left.id) && renderer.isInstrumentReady(right.id) { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    precondition(renderer.isInstrumentReady(left.id) && renderer.isInstrumentReady(right.id), "both SF2 samplers must finish preparing")
    snapshot.transport.playing = true; snapshot.transport.subPlay.playing = true
    try renderer.update(snapshot, revision: 1)
    let nodes = engine.attachedNodes
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    func rms() throws -> SIMD2<Double> {
        var squares = SIMD2<Double>(repeating: 0), count = 0.0
        for block in 0..<24 {
            let status = try engine.renderOffline(512, to: output)
            precondition(status == .success, "MIDI patch changes must not interrupt audio rendering")
            if block >= 12 {
                for frame in 0..<Int(output.frameLength) {
                    for channel in 0..<2 {
                        let sample = Double(output.floatChannelData![channel][frame])
                        precondition(sample.isFinite)
                        squares[channel] += sample * sample
                    }
                    count += 1
                }
            }
        }
        precondition(engine.attachedNodes == nodes && engine.isRunning, "MIDI input changes must preserve samplers and scheduled Play/SubPlay nodes")
        return SIMD2(sqrt(squares.x / count), sqrt(squares.y / count))
    }
    let devices = AudioDeviceSettings.shared.midiSlots
    renderer.receiveMIDI(device: devices[0], status: 0x90, number: 60, value: 110)
    let sounding = try rms()
    precondition(sounding.x > 0.0001 && sounding.y > 0.0001, "both independently panned instruments must produce PCM: \(sounding)")
    renderer.previewMIDIInput(left.id, slot: 0)
    let changed = try rms()
    precondition(changed.x < 0.000001 && changed.y > 0.0001, "changing one MIDI input must release only that instrument: \(changed)")
    renderer.receiveMIDI(device: devices[0], status: 0x90, number: 67, value: 100)
    let oldInput = try rms()
    precondition(oldInput.x < 0.000001 && oldInput.y > 0.0001, "old input must no longer trigger the changed track")
    renderer.previewMIDIInput(right.id, slot: 1)
    renderer.previewMIDIInput(UUID(), slot: 0)
    renderer.previewMIDIInput(left.id, slot: 4)
    let untouched = try rms()
    precondition(untouched.x < 0.000001 && untouched.y > 0.0001, "same/invalid input changes must not release another track")
    renderer.previewMIDIInput(left.id, slot: 2)
    renderer.receiveMIDI(device: devices[1], status: 0x90, number: 72, value: 110)
    let newInput = try rms()
    precondition(newInput.x > 0.0001 && newInput.y > 0.0001, "new slot must trigger the changed track while other notes continue: \(newInput), devices \(devices)")
    renderer.previewMIDIInput(left.id, slot: 1)
    renderer.receiveMIDI(device: devices[0], status: 0x90, number: 60, value: 110)
    let immediateNewNote = try rms()
    precondition(immediateNewNote.x > 0.0001 && immediateNewNote.y > 0.0001, "active-to-active rerouting must release old notes without discarding an immediate new Note On: \(immediateNewNote)")
    renderer.previewMIDIInput(left.id, slot: 0)
    let released = try rms()
    precondition(released.x < 0.000001 && released.y > 0.0001, "disabling the new input must release its notes only")
    renderer.stop()
    print("INCREMENTAL_MIDI_INPUT_PER_TRACK_NOTE_RELEASE_AND_PLAY_SUBPLAY_TOPOLOGY_PCM_OK rate=\(rate)")
}
Task { @MainActor in
    do { try await run(); exit(0) } catch { print(error); exit(1) }
}
RunLoop.main.run()
