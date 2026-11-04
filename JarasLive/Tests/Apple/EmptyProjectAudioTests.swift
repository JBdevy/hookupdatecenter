import Foundation
import AVFoundation
import Darwin

setbuf(stdout, nil)

// Real Core Audio, with the final output muted: offline rendering does not
// reproduce a hardware graph that was allocated before its first tracks.
@MainActor func runEmptyProjectAudioTests() async throws {
    // Keep these overrides local to the test process, without changing the
    // user's metronome preferences while their project is open.
    UserDefaults.standard.setVolatileDomain([
        "jaras.metronome.enabled": true,
        "jaras.metronome.preset": "Digital",
        "jaras.metronome.gainA": 0.0,
        "jaras.metronome.gainB": 0.0,
        "jaras.metronome.output": try JSONEncoder().encode(OutputPatch.stereo)
    ], forName: UserDefaults.argumentDomain)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("empty-tab-audio-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 4)!
    pcm.frameLength = pcm.frameCapacity
    for channel in 0..<2 { pcm.floatChannelData![channel].update(repeating: 0.03, count: Int(pcm.frameLength)) }
    try AVAudioFile(forWriting: folder.appendingPathComponent("tone.wav"), settings: format.settings).write(from: pcm)
    let primary = StemAudioPlayback(engine: AudioDeviceSettings.shared.engine)
    primary.setLicenseAllowed(false)
    try primary.startDeviceSession()
    defer { primary.prepareForClosing() }
    for dynamic in [false, true] {
        let engine = AVAudioEngine()
        let audio = StemAudioPlayback(engine: engine, auxiliarySelectedHardware: true)
        audio.setLicenseAllowed(false)
        try audio.startDeviceSession()
        audio.open(directory: folder)
        defer { audio.prepareForClosing() }
        var project = Project.empty(name: "Empty project tab")
        var track = Track(id: UUID(), name: "Pasted audio", role: .other)
        track.clips = [AudioClip(id: UUID(), name: "Copied tone", startTime: 10, duration: 4, audioFile: AudioFile(path: "tone.wav"))]
        var state = ShowSnapshot(project: project, transport: TransportState(playing: false,
            songId: project.songs[0].id, position: 10, queue: QueueState(), loop: LoopState(enabled: false),
            subPlay: SubPlayState(playing: false, position: 0)))
        if dynamic {
            try audio.update(state, revision: 1)
            try await Task.sleep(nanoseconds: 150_000_000)
            precondition(engine.isRunning, "The empty tab must already have an allocated hardware graph")
        }
        project.songs[0].tracks = [track]; project.songs[0].duration = 14
        state.project = project
        try audio.update(state, revision: 2)
        let metronomeRoute = Mirror(reflecting: audio).children.first { $0.label == "metronomeRoute" }!.value as! AVAudioUnitEffect
        JarasChannelRouter.setInputMeteringEnabled(metronomeRoute, enabled: true)
        try await Task.sleep(nanoseconds: 200_000_000)
        state.transport.playing = true
        try audio.update(state, revision: 2)
        let began = ProcessInfo.processInfo.systemUptime
        var peak = 0.0, clickPeak: Float = 0
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 30_000_000)
            state.transport.position = 10 + ProcessInfo.processInfo.systemUptime - began
            try audio.update(state, revision: 2)
            peak = max(peak, audio.masterMeter.level)
            clickPeak = max(clickPeak, JarasChannelRouter.takeInputPeak(metronomeRoute, channel: 0))
        }
        print("EMPTY_TAB_PASTE_REALTIME_AUDIO dynamic=\(dynamic) peak=\(peak) metronome=\(clickPeak)")
        precondition(peak > 0.025 && peak < 0.035, "The pasted source must reach the Master once, at its original gain")
        precondition(clickPeak > 0.1, "The metronome must also render after pasting tracks into the empty tab")
        precondition(engine.isRunning && engine.mainMixerNode.outputVolume == 0, "The test must keep physical output silent")
    }
}
Task { @MainActor in
    do { try await runEmptyProjectAudioTests(); exit(0) }
    catch { print("EMPTY_TAB_AUDIO_ERROR", error); exit(1) }
}
dispatchMain()
