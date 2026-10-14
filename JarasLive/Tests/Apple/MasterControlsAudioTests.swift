import Foundation
import AVFoundation
import Darwin

setbuf(stdout, nil)
UserDefaults.standard.setVolatileDomain(["jaras.metronome.enabled": false], forName: UserDefaults.argumentDomain)

@MainActor func verifyMasterControls() throws {
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("master-controls-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 12))!
    source.frameLength = source.frameCapacity
    source.floatChannelData![0].update(repeating: 0.08, count: Int(source.frameLength))
    source.floatChannelData![1].update(repeating: 0.12, count: Int(source.frameLength))
    do {
        let file = try AVAudioFile(forWriting: directory.appendingPathComponent("stereo.wav"), settings: format.settings)
        try file.write(from: source)
    }
    // Use the application's realtime voice path with a manually pulled device:
    // these tests never open or change the user's audio interface.
    for grouped in [false, true] { for hardware in [false, true] {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        let audio = StemAudioPlayback(engine: engine, realtime: true)
        audio.open(directory: directory)
        defer { audio.prepareForClosing() }
        var project = Project.empty(name: "Master controls PCM")
        var track = Track(id: UUID(), name: "Source", role: .other)
        track.outputs = [hardware ? .stereo : .master]
        track.clips = [AudioClip(id: UUID(), name: "Stereo", startTime: 0, duration: 12,
                                audioFile: AudioFile(path: "stereo.wav"))]
        if grouped {
            var parent = Track(id: UUID(), name: "Parent", role: .other)
            parent.outputs = track.outputs
            track.parentTrackID = parent.id; track.outputs = [.masterGroup]
            project.songs[0].tracks = [parent, track]
        } else { project.songs[0].tracks = [track] }
        project.masterVolume = 0.5; project.masterPan = -0.5
        var timing = project.songs[0].projectTime; timing.timebase = .free
        project.songs[0].timeSettings = timing
        var state = ShowSnapshot(project: project, transport: TransportState(playing: true,
            songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false),
            subPlay: SubPlayState(playing: false, position: 0)))
        try audio.update(state, revision: 1)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        func check(_ gain: Double, _ pan: Double, _ label: String, muted: Bool = false) throws {
            let nodes = engine.attachedNodes
            var actual = SIMD2<Double>(repeating: 0)
            for block in 0..<24 {
                let status = try engine.renderOffline(512, to: buffer)
                precondition(status == .success, "\(label): render failed")
                if block >= 16 {
                    for channel in 0..<2 { for frame in 0..<Int(buffer.frameLength) {
                        actual[channel] = max(actual[channel], Double(abs(buffer.floatChannelData![channel][frame])))
                    } }
                }
            }
            let expected = hardware ? SIMD2(0.08, 0.12) : muted ? .zero :
                SIMD2(0.08 * gain * (1 - max(0, pan)), 0.12 * gain * (1 + min(0, pan)))
            precondition(abs(actual.x - expected.x) < 0.00003 && abs(actual.y - expected.y) < 0.00003,
                         "\(label): grouped=\(grouped), hardware=\(hardware), PCM=\(actual), expected=\(expected)")
            precondition(engine.isRunning && engine.attachedNodes == nodes, "Scalar Master edits must retain the graph")
        }
        try check(0.5, -0.5, "Saved Master volume/pan")
        audio.previewVolume(nil, gain: 0.25)
        try check(0.25, -0.5, "Live Master fader")
        for pan in [-1.0, -0.25, 0.0, 0.25, 1.0] {
            audio.previewMasterPan(pan)
            try check(0.25, pan, "Live Master pan \(pan)")
        }
        audio.previewMute(nil, muted: true)
        try check(0.25, 1, "Master mute", muted: true)
        audio.previewMute(nil, muted: false)
        audio.previewVolume(nil, gain: 0)
        try check(0, 1, "Master fader at zero")
        audio.previewVolume(nil, gain: 1.5); audio.previewMasterPan(0)
        try check(1.5, 0, "Positive Master fader gain")

        // Rebuilding the Master insert chain must retain the post-FX controls.
        var fx = NativeFXSettings(); fx.inserted = ["Delay"]
        fx.delayEnabled = true; fx.delayMix = 0
        state.project.masterFX = fx; state.project.masterVolume = 0.2; state.project.masterPan = 0.5
        state.transport.position = Double(engine.manualRenderingSampleTime) / rate
        try audio.update(state, revision: 2)
        try check(0.2, 0.5, "Master insert chain plus saved controls")
        audio.previewVolume(nil, gain: 0.4); audio.previewMasterPan(-1)
        try check(0.4, -1, "Master controls after FX chain rebuild")
        print("MASTER_FADER_PAN_MUTE_SAVED_LIVE_AND_POST_FX_PCM_OK rate=\(rate) group=\(grouped) hardwareBypass=\(hardware)")
    } }
}
try MainActor.assumeIsolated { try verifyMasterControls() }
