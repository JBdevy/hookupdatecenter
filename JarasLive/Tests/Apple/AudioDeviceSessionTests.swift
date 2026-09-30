import Foundation
import AVFoundation
import Darwin

setbuf(stdout, nil)

@MainActor func runDeviceSessionTests() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let audio = StemAudioPlayback(engine: engine)
    try audio.startDeviceSession()
    precondition(engine.isRunning, "the device session starts before a project or Play")
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    func requireContinuousSilence() throws {
        let before = engine.manualRenderingSampleTime
        for _ in 0..<64 {
            let status = try engine.renderOffline(512, to: output)
            precondition(status == .success, "idle output must render continuously")
            for channel in 0..<2 {
                for sample in 0..<Int(output.frameLength) {
                    precondition(output.floatChannelData![channel][sample] == 0, "keepalive must be digital silence")
                }
            }
        }
        precondition(engine.manualRenderingSampleTime > before, "the render clock keeps advancing while stopped")
    }
    try requireContinuousSilence()
    var project = Project.empty(name: "Empty idle session")
    project.songs[0].tracks = []; project.masterMute = true
    var snapshot = ShowSnapshot(project: project, transport: TransportState(playing: false, songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    audio.open(directory: directory)
    try audio.update(snapshot, revision: 1)
    let chain = audio.effects(for: nil)
    for _ in 0..<3 {
        snapshot.transport.playing = true
        try audio.update(snapshot, revision: 1)
        snapshot.transport.playing = false; snapshot.transport.paused = true
        try audio.update(snapshot, revision: 1)
        audio.stop()
        precondition(engine.isRunning, "Stop and Pause must keep the realtime device active")
        precondition(audio.effects(for: nil) === chain, "idle must preserve the audio graph")
        try requireContinuousSilence()
    }
    audio.prepareForClosing()
    precondition(!engine.isRunning, "closing releases the device")
    print("IDLE_EMPTY_MUTED_PROJECT_PLAY_PAUSE_STOP_CONTINUOUS_DIGITAL_SILENCE_OK rate=\(rate)")

    // Exercise the physical render clock using silence only. This engine does
    // not change the user's selected device, sample rate, or buffer settings.
    let hardware = AVAudioEngine()
    let live = StemAudioPlayback(engine: hardware)
    var failure: Error?
    live.onError = { failure = $0 }
    try live.startDeviceSession()
    try await Task.sleep(nanoseconds: 200_000_000)
    for _ in 0..<3 {
        let before = hardware.outputNode.lastRenderTime?.sampleTime
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(hardware.isRunning, "idle hardware must remain active without UI transport updates")
        if let before, let after = hardware.outputNode.lastRenderTime?.sampleTime {
            precondition(after > before, "hardware must keep requesting render buffers")
        } else { preconditionFailure("the physical output must have an active render clock") }
        live.stop()
    }
    let retained = live.effects(for: nil)
    hardware.stop()
    try await Task.sleep(nanoseconds: 1_400_000_000)
    precondition(failure == nil, "device recovery failed: \(String(describing: failure))")
    precondition(hardware.isRunning, "an unexpectedly stopped output recovers while idle, before Play")
    precondition(live.effects(for: nil) === retained, "same-format recovery preserves plugin instances")
    live.prepareForClosing()
    try await Task.sleep(nanoseconds: 1_200_000_000)
    precondition(!hardware.isRunning, "the idle watchdog must not reopen a closed session")
    print("PHYSICAL_IDLE_RENDER_CLOCK_RECOVERY_AND_FINAL_RELEASE_OK")
}

Task { @MainActor in
    do { try await runDeviceSessionTests(); exit(0) }
    catch { print("DEVICE_SESSION_ERROR", error); exit(1) }
}
RunLoop.main.run()
