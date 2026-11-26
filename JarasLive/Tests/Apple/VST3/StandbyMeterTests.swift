import Foundation
import AVFoundation
import Darwin
@MainActor func runStandbyMeterTest() async throws {
    let path = ProcessInfo.processInfo.environment["JARAS_TEST_VST3"]!
    var error: NSError?
    let plugin = JarasVST3.scan(path, error: &error)[0]
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let engine = AVAudioEngine(), format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let audio = StemAudioPlayback(engine: engine, realtime: true)
    audio.open(directory: directory)
    var project = Project.empty(name: "Stopped instrument meters")
    var track = Track(id: UUID(), name: "VST3", role: .keys)
    let instance = ExternalPlugin(classID: plugin["classID"] as! String, name: "Gain fixture", path: path)
    var fx = NativeFXSettings(); fx.externalPlugins = [instance]; fx.inserted = [instance.effectKey]
    track.fx = fx; track.volume = 0.5
    project.songs[0].tracks = [track]; project.masterVolume = 0.25
    let snapshot = ShowSnapshot(project: project, transport: TransportState(playing: false, songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    try audio.update(snapshot, revision: 1)
    let meter = audio.meter(for: track.id)
    // Match the UI: arm after the project graph has been opened. Opening a
    // project resets the previous graph's instrument rendering state.
    audio.setArmedInstrumentTracks([track.id])
    let node = audio.effects(for: track.id)!.externalNode(instance.id)!
    JarasVST3.sendMIDI(node, status: 0x90, data1: 60, data2: 100)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    func render() async throws -> Float {
        // Feed the graph continuously while yielding to its independent meter
        // clock; a burst followed by silence legitimately decays the meter.
        for _ in 0..<20 {
            let status = try engine.renderOffline(512, to: buffer)
            precondition(status == .success)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return buffer.floatChannelData![0][100]
    }
    let initial = try await render()
    precondition(abs(initial - 0.015625) < 0.00001)
    precondition(meter.levels.x > 0.05 && meter.levels.y > 0.05, "stereo track meters update from their own post-fader VST3 audio without transport ticks")
    precondition(audio.masterMeter.level > 0.01, "master meters remain active for stopped transport instruments")
    audio.previewVolume(nil, gain: 0.01)
    let lowered = try await render()
    precondition(lowered < initial * 0.05)
    precondition(meter.level > 0.05, "track meters do not depend on the Master fader")
    audio.previewMute(track.id, muted: true)
    let muted = try await render()
    precondition(abs(muted) < 0.000001)
    audio.prepareForClosing()
    precondition(!engine.isRunning)
    print("STOPPED_VST3_TRACK_MASTER_STEREO_METERS_INDEPENDENT_CLOCK_FADER_MUTE_PCM_OK")
}

Task { @MainActor in
    do { try await runStandbyMeterTest(); exit(0) }
    catch { print(error); exit(1) }
}
RunLoop.main.run()
