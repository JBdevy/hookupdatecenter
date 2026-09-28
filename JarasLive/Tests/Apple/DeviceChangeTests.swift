import Foundation
import AVFoundation
import AudioToolbox
import Darwin

setbuf(stdout, nil)

@MainActor func runDeviceTests() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    do {
        let file = try AVAudioFile(forWriting: directory.appendingPathComponent("tone.wav"), settings: fileFormat.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: 44100 * 12)!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0.1, count: Int(buffer.frameLength)) }
        try file.write(from: buffer)
    }
    var project = Project.empty(name: "Device recovery")
    var track = Track(id: UUID(), name: "Tone", role: .keys)
    track.clips = [AudioClip(id: UUID(), name: "Tone", startTime: 0, duration: 12, audioFile: AudioFile(path: "tone.wav"))]
    project.songs[0].tracks = [track]
    var snapshot = ShowSnapshot(project: project, transport: TransportState(playing: true, songId: project.songs[0].id, position: 1, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: true, position: 2)))

    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: fileFormat, maximumFrameCount: 512)
    let renderer = StemAudioPlayback(engine: engine, realtime: false)
    renderer.open(directory: directory)
    try renderer.update(snapshot, revision: 1)
    func renderedPeak(channel: Int = 0) throws -> Float {
        let output = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
        var peak: Float = 0
        for iteration in 0..<24 {
            let status = try engine.renderOffline(512, to: output)
            precondition(status == .success)
            if iteration > 15 {
                for index in 0..<Int(output.frameLength) { peak = max(peak, abs(output.floatChannelData![channel][index])) }
            }
        }
        return peak
    }
    func requirePeak(_ minimum: Float, _ message: String) throws {
        let peak = try renderedPeak()
        precondition(peak > minimum, "\(message): \(peak)")
    }
    try requirePeak(0.19, "initial dual-head audio")
    let chain = renderer.effects(for: track.id)!
    engine.stop()
    try renderer.reconfigureDevice()
    precondition(renderer.effects(for: track.id) === chain, "same-format output switches retain the effect chain and native plugin editor instance")
    try requirePeak(0.19, "both transport heads must resume without another Play or project edit")
    print("SAME_FORMAT_OUTPUT_SWITCH_RESUMES_BOTH_HEADS_RETAINS_FX_OK")

    for (rate, channels) in [(48000.0, AVAudioChannelCount(4)), (44100.0, AVAudioChannelCount(2))] {
        engine.stop(); engine.disableManualRenderingMode()
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels)!
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        try renderer.reconfigureDevice()
        try requirePeak(0.19, "audio is restored when the output sample rate/channel layout changes")
        print("OUTPUT_FORMAT_SWITCH_RESUMES_BOTH_HEADS_PCM_OK rate=\(rate) channels=\(channels)")
    }
    snapshot.transport.playing = false; snapshot.transport.subPlay.playing = false
    try renderer.update(snapshot, revision: 1)
    try renderer.reconfigureDevice()
    precondition(!engine.isRunning, "a stopped transport must not be restarted as playback")
    snapshot.transport.playing = true
    try renderer.update(snapshot, revision: 1)
    try requirePeak(0.09, "Play works after switching the device while stopped")
    renderer.prepareForClosing()

    let settings = AudioDeviceSettings.shared
    precondition(!settings.devices.contains { $0.id.hasPrefix("CADefaultDeviceAggregate-") }, "engine-owned temporary aggregates must not be selectable")
    let originalDevice = settings.selectedUID
    let originalBuffer = settings.bufferFrames
    defer {
        settings.select(originalDevice)
        if settings.bufferChoices.contains(originalBuffer) { settings.setBuffer(originalBuffer) }
    }
    let liveEngine = settings.engine
    let live = StemAudioPlayback(engine: liveEngine)
    live.onError = { print("REAL_DEVICE_RECOVERY_ERROR", $0) }
    live.open(directory: directory)
    snapshot.project.masterVolume = 0.05
    snapshot.transport.subPlay.playing = false
    let meter = live.meter(for: track.id)
    try live.update(snapshot, revision: 1)
    live.prepareAfterDeviceChange = { try live.update(snapshot, revision: 1) }
    try await Task.sleep(nanoseconds: 350_000_000)
    print("REAL_DEVICE_BASELINE", settings.deviceName, "running", liveEngine.isRunning, "track", meter.level, "master", live.masterMeter.level)
    for device in settings.devices.reversed() {
        settings.select(device.id)
        try await Task.sleep(nanoseconds: 450_000_000)
        precondition(settings.error.isEmpty, "device selection failed: \(settings.error)")
        precondition(liveEngine.isRunning, "device switch must restart the engine")
        var hardware: UInt32 = 0, bytes = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioUnitGetProperty(liveEngine.outputNode.audioUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &hardware, &bytes)
        precondition(status == noErr && hardware == device.hardwareID, "the running engine must use the selected physical output")
        print("REAL_DEVICE_LEVELS", device.name, "track", meter.level, "master", live.masterMeter.level)
        precondition(meter.level > 0.06 && live.masterMeter.level > 0.003, "stereo audio must reach the track and Master on the selected physical output")
        let retained = live.effects(for: track.id)
        settings.select(device.id)
        precondition(live.effects(for: track.id) === retained && liveEngine.isRunning, "reselecting the same device must not stop playback")
        print("REAL_DEVICE_SWITCH_ENGINE_ROUTE_STEREO_AUDIO_OK \(device.name)")
    }
    if let buffer = settings.bufferChoices.first(where: { $0 != settings.bufferFrames && $0 >= 256 }) {
        settings.setBuffer(buffer)
        try await Task.sleep(nanoseconds: 450_000_000)
        precondition(liveEngine.isRunning && meter.level > 0.06 && live.masterMeter.level > 0.003, "buffer changes must resume scheduled audio")
        print("REAL_BUFFER_CHANGE_RESUMES_PCM_OK frames=\(buffer)")
    }
    settings.select(originalDevice)
    if settings.bufferChoices.contains(originalBuffer) { settings.setBuffer(originalBuffer) }
    try await Task.sleep(nanoseconds: 250_000_000)
    live.prepareForClosing()
    print("DEVICE_RECOVERY_ALL_CHECKS_OK")
}

Task { @MainActor in
    do { try await runDeviceTests(); exit(0) }
    catch { print("DEVICE_RECOVERY_ERROR", error); exit(1) }
}
RunLoop.main.run()
