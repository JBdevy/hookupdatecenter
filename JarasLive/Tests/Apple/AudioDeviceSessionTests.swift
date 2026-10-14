import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
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

    // Exercise the selected-output engine alongside another shared Core Audio client.
    // Throw assertions here so defer always closes the test engines on failure.
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw NSError(domain: "AudioDeviceSessionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    let settings = AudioDeviceSettings.shared
    let originalOutput = settings.selectedUID, originalInput = settings.inputUID, originalError = settings.error
    let preferences = UserDefaults.standard
    let savedOutput = preferences.object(forKey: "jaras.audioOutputUID")
    let savedInput = preferences.object(forKey: "catlive.audioInputUID")
    let selected = StemAudioPlayback(engine: settings.engine)
    defer {
        selected.prepareForClosing()
        settings.selectInput(originalInput)
        settings.select(originalOutput)
        settings.error = originalError
        if let savedOutput { preferences.set(savedOutput, forKey: "jaras.audioOutputUID") }
        else { preferences.removeObject(forKey: "jaras.audioOutputUID") }
        if let savedInput { preferences.set(savedInput, forKey: "catlive.audioInputUID") }
        else { preferences.removeObject(forKey: "catlive.audioInputUID") }
    }
    let target = settings.devices.first(where: { $0.id == originalOutput }) ?? settings.devices.first
    guard let target else { throw NSError(domain: "AudioDeviceSessionTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "A physical output device is required for the selected-device integration test."]) }
    func requireSharedOutput() throws {
        try require(settings.outputDeviceIsBound, "the engine must remain bound to the selected physical output")
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(target.hardwareID, &address) {
            var owner: pid_t = -1, bytes = UInt32(MemoryLayout<pid_t>.size)
            let result = AudioObjectGetPropertyData(target.hardwareID, &address, 0, nil, &bytes, &owner)
            try require(result == noErr && bytes == MemoryLayout<pid_t>.size, "the selected output ownership must be readable")
            try require(owner != getpid(), "CatLive must not reserve exclusive device access")
        }
    }
    var selectionFailure: Error?
    selected.onError = { selectionFailure = $0 }
    func waitForSelectedOutput() async throws {
        for _ in 0..<30 {
            if let selectionFailure { throw selectionFailure }
            if settings.engine.isRunning { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try require(settings.engine.isRunning, "selecting an output must recover the selected-device session")
    }

    settings.selectInput("")
    settings.select(target.id)
    try selected.startDeviceSession()
    try await Task.sleep(nanoseconds: 1_400_000_000)
    try requireSharedOutput()
    // A second client can render at the same time on the same physical output.
    let concurrentEngine = AVAudioEngine()
    guard let concurrentUnit = concurrentEngine.outputNode.audioUnit else {
        throw NSError(domain: "AudioDeviceSessionTests", code: 3)
    }
    var targetID = target.hardwareID
    let concurrentBinding = AudioUnitSetProperty(concurrentUnit, kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global, 0, &targetID, UInt32(MemoryLayout<AudioDeviceID>.size))
    try require(concurrentBinding == noErr, "the second client must bind the selected output")
    let concurrent = StemAudioPlayback(engine: concurrentEngine)
    defer { concurrent.prepareForClosing() }
    try concurrent.startDeviceSession()
    try await Task.sleep(nanoseconds: 300_000_000)
    let selectedTime = settings.engine.outputNode.lastRenderTime?.sampleTime
    let concurrentTime = concurrentEngine.outputNode.lastRenderTime?.sampleTime
    try await Task.sleep(nanoseconds: 300_000_000)
    try require(settings.engine.isRunning && concurrentEngine.isRunning, "both shared clients must run simultaneously")
    try require((settings.engine.outputNode.lastRenderTime?.sampleTime ?? 0) > (selectedTime ?? Int64.max), "CatLive's shared render clock must advance")
    try require((concurrentEngine.outputNode.lastRenderTime?.sampleTime ?? 0) > (concurrentTime ?? Int64.max), "the second client's render clock must advance")
    try requireSharedOutput()
    concurrent.prepareForClosing()
    print("TWO_SHARED_CLIENTS_RENDER_ON_SELECTED_OUTPUT_OK")
    selected.prepareForClosing()
    settings.select("none")
    try selected.startDeviceSession()
    selected.open(directory: directory)
    snapshot.transport.playing = true; snapshot.transport.paused = false
    try selected.update(snapshot, revision: 2)
    try await Task.sleep(nanoseconds: 1_200_000_000)
    try require(!settings.engine.isRunning, "None must stay stopped even when Play and the watchdog run")

    settings.select(target.id)
    try await waitForSelectedOutput()
    try requireSharedOutput()
    selected.stop()
    try await Task.sleep(nanoseconds: 200_000_000)
    try require(settings.engine.isRunning, "Stop must preserve the selected output session")
    try requireSharedOutput()

    settings.select("none")
    try selected.update(snapshot, revision: 2)
    try await Task.sleep(nanoseconds: 1_200_000_000)
    try require(!settings.engine.isRunning, "None must stop the previously selected output without watchdog reopening it")
    settings.select(target.id)
    try await waitForSelectedOutput()
    try requireSharedOutput()
    selected.prepareForClosing()
    try await Task.sleep(nanoseconds: 1_200_000_000)
    try require(!settings.engine.isRunning, "closing must stop hardware and disable recovery")
    print("SELECTED_OUTPUT_SHARED_NONE_STOP_RESELECT_WATCHDOG_CLOSE_OK device=\(target.name)")
}

Task { @MainActor in
    do { try await runDeviceSessionTests(); exit(0) }
    catch { print("DEVICE_SESSION_ERROR", error); exit(1) }
}
RunLoop.main.run()
