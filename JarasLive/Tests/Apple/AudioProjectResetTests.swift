import Foundation
import AVFoundation
import Darwin

setbuf(stdout, nil)
UserDefaults.standard.setVolatileDomain(["jaras.metronome.enabled": false], forName: UserDefaults.argumentDomain)

@MainActor func runAudioProjectResetTests() throws {
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("audio-project-reset-" + UUID().uuidString)
    let firstDirectory = root.appendingPathComponent("First"), secondDirectory = root.appendingPathComponent("Second")
    try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func write(_ path: URL, value: Float) throws {
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 4))!
        pcm.frameLength = pcm.frameCapacity
        for channel in 0..<2 { pcm.floatChannelData![channel].update(repeating: value, count: Int(pcm.frameLength)) }
        let file = try AVAudioFile(forWriting: path, settings: format.settings)
        try file.write(from: pcm)
    }
    try write(firstDirectory.appendingPathComponent("legacy.wav"), value: 0.1)
    // Reusing a basename in another project must neither revive an old item
    // editor nor inherit that preceding project's missing-media blacklist.
    try write(secondDirectory.appendingPathComponent("legacy.wav"), value: 0.3)
    try write(secondDirectory.appendingPathComponent("shared.wav"), value: 0.25)
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let audio = StemAudioPlayback(engine: engine, realtime: false)
    defer { audio.prepareForClosing() }
    var failures: [String] = []
    func check(_ value: Bool, _ message: String) {
        if !value { failures.append(message); print("AUDIO_PROJECT_RESET_FAIL", message) }
    }
    func snapshot(_ project: Project) -> ShowSnapshot {
        ShowSnapshot(project: project, transport: TransportState(playing: true,
            songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false),
            subPlay: SubPlayState(playing: false, position: 0)))
    }
    var first = Project.empty(name: "First")
    first.songs[0].duration = 4
    first.songs[0].parts = [Part(id: UUID(), name: "First", startTime: 0, endTime: 4)]
    var track = Track(id: UUID(), name: "Old track", role: .other)
    let oldClip = AudioClip(id: UUID(), name: "Old item", startTime: 0, duration: 4, audioFile: AudioFile(path: "legacy.wav"))
    track.clips = [oldClip]
    var click = Track(id: UUID(), name: "Click", role: TrackRole(rawValue: TrackKind.click.rawValue))
    click.clickSound = AudioFile(path: "legacy.wav")
    first.songs[0].tracks = [track, click]
    precondition(first.insertClickItems(track: click.id) == 1)
    var fx = NativeFXSettings(); fx.inserted = ["Delay"]; fx.delayEnabled = true; fx.delayMix = 20
    first.masterFX = fx; first.masterVolume = 0.5; first.masterPan = -0.5
    audio.open(directory: firstDirectory)
    audio.setMissingAudioPaths(["shared.wav"])
    try audio.update(snapshot(first), revision: 1)
    audio.armedMIDIRecordingTracks = [track.id]
    audio.setArmedInstrumentTracks([track.id])
    audio.observeEffect(nil, effect: "Delay", active: true)
    let oldMaster = audio.effects(for: nil)
    let oldMeter = audio.meter(for: track.id)
    oldMeter.update(peak: 0.9, elapsed: 1.0 / 30)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    for _ in 0..<8 { _ = try engine.renderOffline(512, to: buffer) }
    audio.setLicenseAllowed(false)
    audio.open(directory: secondDirectory)
    check(engine.mainMixerNode.outputVolume == 0, "A project switch must preserve the global license gate")
    check(audio.effects(for: oldClip.id) == nil, "The preceding item must not create a voice in the new media directory")
    check(audio.effects(for: track.id) == nil, "The preceding track must not survive the project switch")
    check(audio.effects(for: nil) !== oldMaster, "The Master must not retain the preceding project's FX chain")
    check(audio.armedMIDIRecordingTracks.isEmpty, "MIDI recording arming must belong only to the current project")
    check(audio.meter(for: track.id) !== oldMeter, "Track meter subscriptions must not retain the preceding project")
    check(engine.attachedNodes.compactMap { $0 as? AVAudioPlayerNode }.isEmpty, "Project switching must detach every old player")
    audio.setLicenseAllowed(true)
    var second = Project.empty(name: "Second")
    second.songs[0].duration = 4
    var next = Track(id: UUID(), name: "New track", role: .other)
    next.clips = [AudioClip(id: UUID(), name: "New item", startTime: 0, duration: 4, audioFile: AudioFile(path: "shared.wav"))]
    second.songs[0].tracks = [next]
    try audio.update(snapshot(second), revision: 1)
    var peak: Float = 0
    for block in 0..<40 {
        let status = try engine.renderOffline(512, to: buffer)
        precondition(status == .success)
        if block >= 20 { for channel in 0..<2 { for frame in 0..<Int(buffer.frameLength) {
            peak = max(peak, abs(buffer.floatChannelData![channel][frame]))
        } } }
    }
    check(abs(peak - 0.25) < 0.0001, "A missing filename in the old project must not silence valid media in the new one (PCM \(peak))")
    audio.armedMIDIRecordingTracks = [next.id]
    let currentMaster = audio.effects(for: nil)
    try audio.reconfigureDevice()
    check(audio.armedMIDIRecordingTracks == [next.id], "A same-project device restart must preserve MIDI arming")
    check(audio.effects(for: nil) === currentMaster, "A same-format device restart must preserve its FX instances")
    audio.prepareForClosing()
    check(!engine.isRunning, "Project close must stop the engine")
    let remaining = engine.attachedNodes.filter { $0 !== engine.mainMixerNode && $0 !== engine.outputNode }
    check(remaining.isEmpty, "Project close must detach all project nodes (remaining \(remaining.count))")
    check(audio.effects(for: next.id) == nil, "A closed project's track FX must no longer be accessible")
    check(audio.armedMIDIRecordingTracks.isEmpty, "Closing must clear pending MIDI recording targets")
    audio.open(directory: secondDirectory)
    try audio.update(snapshot(second), revision: 1)
    check(audio.effects(for: next.id) != nil, "A clean reopen must create the current track's FX")
    audio.prepareForClosing()
    if !failures.isEmpty { throw ProjectError.invalid(failures.joined(separator: "; ")) }
    print("AUDIO_PROJECT_SWAP_CLEARS_MEDIA_FX_MIDI_METERS_AND_CLOSE_DETACHES_GRAPH_OK rate=\(rate)")
}
try MainActor.assumeIsolated { try runAudioProjectResetTests() }
