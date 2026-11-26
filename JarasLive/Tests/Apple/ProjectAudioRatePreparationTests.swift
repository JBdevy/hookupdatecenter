import Foundation
import AVFoundation
import Darwin
setbuf(stdout, nil)

@MainActor func run() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-rate-plan-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for rate in [22050.0, 44100, 48000] {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)!
        pcm.frameLength = 128
        for channel in 0..<2 { pcm.floatChannelData![channel].initialize(repeating: 0.1, count: 128) }
        try AVAudioFile(forWriting: folder.appendingPathComponent("\(Int(rate)).wav"), settings: format.settings).write(from: pcm)
    }
    func project(_ paths: [String]) -> Project {
        var value = Project.empty(name: "Rate preparation")
        var track = Track(id: UUID(), name: "Sources", role: .other)
        track.clips = paths.enumerated().map { index, path in
            AudioClip(id: UUID(), name: path, startTime: Double(index), duration: 0.001, audioFile: AudioFile(path: path))
        }
        value.songs[0].tracks = [track]
        return value
    }
    let hardware = AVAudioEngine()
    let audio = StemAudioPlayback(engine: hardware, auxiliarySelectedHardware: true)
    audio.setLicenseAllowed(false)
    try audio.startDeviceSession()
    defer { audio.prepareForClosing() }
    let deviceRate = hardware.outputNode.outputFormat(forBus: 0).sampleRate
    let large = project(Array(repeating: "44100.wav", count: 240) + Array(repeating: "48000.wav", count: 16))
    try await audio.openPreparedProject(directory: folder, project: large)
    precondition(audio.processingSampleRate == 44100)
    precondition(hardware.outputNode.outputFormat(forBus: 0).sampleRate == deviceRate, "Preparing the project must retain the hardware sample rate")
    try audio.reconfigureDevice()
    precondition(audio.processingSampleRate == 44100, "Device recovery must retain the prepared project clock")
    try await audio.openPreparedProject(directory: folder, project: project(Array(repeating: "44100.wav", count: 255)))
    precondition(audio.processingSampleRate == deviceRate, "A new small project must follow hardware rather than inherit the previous plan")
    try await audio.openPreparedProject(directory: folder, project: project(Array(repeating: "44100.wav", count: 128) + Array(repeating: "48000.wav", count: 128)))
    precondition(audio.processingSampleRate == deviceRate, "A balanced collection must not choose an arbitrary clock")
    try await audio.openPreparedProject(directory: folder, project: project(Array(repeating: "22050.wav", count: 240) + Array(repeating: "48000.wav", count: 16)))
    precondition(audio.processingSampleRate == deviceRate, "Low-rate speech files must not lower the processing clock of full-band material")
    try await audio.openPreparedProject(directory: folder, project: project(Array(repeating: "missing.wav", count: 256)))
    precondition(audio.processingSampleRate == deviceRate, "Missing media must leave the project openable for recovery")
    let canceled = Task { @MainActor in
        try await audio.openPreparedProject(directory: folder.appendingPathComponent("canceled"), project: project(["44100.wav"]))
    }
    canceled.cancel()
    do { try await canceled.value; preconditionFailure("Canceled preparation must throw") }
    catch is CancellationError { }
    precondition(audio.mediaDirectory == folder, "Canceled preparation must retain the active project")
    print("PROJECT_AUDIO_RATE_LARGE_MIXED_SMALL_RESET_RECOVERY_QUALITY_MISSING_CANCEL_OK hardware=\(deviceRate)")
}
Task { @MainActor in do { try await run(); exit(0) } catch { print(error); exit(1) } }
dispatchMain()
