import Foundation
import AVFoundation

setbuf(stdout, nil)
UserDefaults.standard.setVolatileDomain(["jaras.metronome.enabled": false], forName: UserDefaults.argumentDomain)

@MainActor func checkItemGainOrder() throws {
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 15))!
    pcm.frameLength = pcm.frameCapacity
    for ch in 0..<2 { for n in 0..<Int(pcm.frameLength) {
        pcm.floatChannelData![ch][n] = 0.4 * Float(sin(Double(n) * 2 * .pi * 440 / rate))
    } }
    try AVAudioFile(forWriting: directory.appendingPathComponent("tone.wav"), settings: format.settings).write(from: pcm)
    let ceiling = pow(10, -0.1 / 20)
    // Both the prepared live source and the player/time-pitch path must feed
    // the item fader into its effects. No hardware or user project is opened.
    for realtime in [false, true] {
        var project = Project.empty(name: "Item gain order")
        var track = Track(id: UUID(), name: "Unity track", role: .other)
        var clip = AudioClip(id: UUID(), name: "Tone", startTime: 0, duration: 15,
                             audioFile: AudioFile(path: "tone.wav"))
        var fx = NativeFXSettings(); fx.appendNative("Limiter")
        fx.limiterParameters.ceiling = -0.1
        clip.fx = fx; clip.gain = 4
        track.clips = [clip]; project.songs[0].tracks = [track]
        var timing = project.songs[0].projectTime; timing.timebase = .free
        project.songs[0].timeSettings = timing
        var state = ShowSnapshot(project: project, transport: TransportState(playing: true,
            songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false),
            subPlay: SubPlayState(playing: false, position: 0)))
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        let audio = StemAudioPlayback(engine: engine, realtime: realtime)
        audio.open(directory: directory)
        defer { audio.prepareForClosing() }
        var errors: [Error] = []; audio.onError = { errors.append($0) }
        var revision: UInt64 = 1
        try audio.update(state, revision: revision)
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        func peak(_ label: String, expected: Double, tolerance: Double = 0.005) throws {
            var peak = 0.0
            for block in 0..<64 {
                let status = try engine.renderOffline(512, to: output)
                precondition(status == .success)
                if block >= 32 { for ch in 0..<2 { for n in 0..<512 {
                    peak = max(peak, Double(abs(output.floatChannelData![ch][n])))
                } } }
                state.transport.position = Double(engine.manualRenderingSampleTime) / rate
                try audio.update(state, revision: revision)
            }
            print("ITEM_GAIN_PEAK \(label) realtime=\(realtime) rate=\(rate) peak=\(peak) expected=\(expected)")
            precondition(abs(peak - expected) < tolerance, "\(label): item volume must precede item FX")
        }
        try peak("Loaded +12 dB item with -0.1 dB limiter", expected: ceiling)
        audio.previewItemGain(clip.id, gain: 8)
        try peak("Live item gain increase", expected: ceiling)
        audio.previewClipFXBypass(clip.id, bypassed: true)
        try peak("Bypass restores boosted dry audio", expected: 3.2)
        audio.previewClipFXBypass(clip.id, bypassed: false)
        audio.previewClipMute(clip.id, muted: true)
        try peak("Mute", expected: 0, tolerance: 0.000001)
        audio.previewClipMute(clip.id, muted: false)
        try peak("Unmute restores limited audio", expected: ceiling)
        audio.previewItemGain(clip.id, gain: 0.25)
        try peak("Attenuation also precedes FX", expected: 0.1)
        // Normalization and item volume retain independent gain ranges.
        audio.previewItemNormalization(clip.id, gain: 8)
        audio.previewItemGain(clip.id, gain: 8)
        audio.previewClipFXBypass(clip.id, bypassed: true)
        try peak("Normalization times volume", expected: 25.6, tolerance: 0.01)
        if !realtime {
            state.project.songs[0].tracks[0].clips[0].gain = 1
            var automation = TrackAutomation()
            automation.envelopes = [TrackEnvelope(target: AutomationTarget(.volume), name: "Volume",
                                                  defaultValue: TrackEnvelope.normalizedGain(4))]
            state.project.songs[0].tracks[0].clips[0].automation = automation
            revision += 1
            try audio.update(state, revision: revision)
            try peak("Automated item gain", expected: ceiling)
        }
        precondition(errors.isEmpty, "Unexpected audio errors: \(errors)")
    }
    print("ITEM_GAIN_BEFORE_FX_OK rate=\(rate)")
}
try MainActor.assumeIsolated { try checkItemGainOrder() }
