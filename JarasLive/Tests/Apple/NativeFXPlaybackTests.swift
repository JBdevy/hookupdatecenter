import Foundation
import AVFoundation

/// Run with JARAS_AUDIO_TEST_SOURCE=Tests/Apple/NativeFXPlaybackTests.swift scripts/test-audio.sh.
/// Exercises the actual track -> group -> master graph, while the transport
/// keeps advancing. No hardware device or currently open project is used.
@MainActor private func checkNativeFXPlayback() throws {
    setbuf(stdout, nil)
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    func sample(_ channel: Int, _ frame: Int) -> Float {
        Float((channel == 0 ? 0.03 : 0.015) * sin(Double(frame) * 2 * .pi * (channel == 0 ? 1000 : 700) / rate + 0.2))
    }
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 30))!
    pcm.frameLength = pcm.frameCapacity
    for ch in 0..<2 { for n in 0..<Int(pcm.frameLength) { pcm.floatChannelData![ch][n] = sample(ch, n) } }
    try AVAudioFile(forWriting: folder.appendingPathComponent("tone.wav"), settings: format.settings).write(from: pcm)

    for target in ["track", "group", "master", "item"] {
    for kind in ["EQ", "Compressor", "Limiter", "Delay", "Reverb", "Pitch"] {
        if let selected = ProcessInfo.processInfo.environment["JARAS_TEST_EFFECT"], selected != kind { continue }
        var project = Project.empty(name: "Native FX live playback")
        let group = Track(id: UUID(), name: "Group", role: .other)
        var track = Track(id: UUID(), name: "Track", role: .other)
        track.parentTrackID = group.id; track.outputs = [.masterGroup]
        track.clips = [AudioClip(id: UUID(), name: "Tone", startTime: 0, duration: 30, audioFile: AudioFile(path: "tone.wav"))]
        project.songs[0].tracks = [group, track]
        var time = project.songs[0].projectTime; time.timebase = .free; project.songs[0].timeSettings = time
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 2048)
        let audio = StemAudioPlayback(engine: engine, realtime: false)
        defer { audio.prepareForClosing() }
        audio.open(directory: folder)
        var state = ShowSnapshot(project: project, transport: TransportState(playing: true, songId: project.songs[0].id,
            position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
        var revision: UInt64 = 1
        try audio.update(state, revision: revision)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048)!
        func tick() throws {
            state.transport.position = Double(engine.manualRenderingSampleTime) / rate
            try audio.update(state, revision: revision)
        }
        for _ in 0..<24 {
            let result = try engine.renderOffline(512, to: buffer)
            precondition(result == .success)
            try tick()
        }
        // Measure the existing player's fixed pipeline latency before editing
        // effects. Bypass/removal must preserve that same clock alignment.
        let referenceFrame = Int(engine.manualRenderingSampleTime)
        let referenceStatus = try engine.renderOffline(512, to: buffer)
        precondition(referenceStatus == .success)
        var latency = 0, referenceError = Double.infinity
        for candidate in 0...1024 {
            var error = 0.0
            for ch in 0..<2 { for n in 0..<64 {
                let difference = Double(buffer.floatChannelData![ch][n] - sample(ch, referenceFrame + n - candidate))
                error += difference * difference
            } }
            if error < referenceError { referenceError = error; latency = candidate }
        }
        precondition(referenceError < 0.00000001, "Dry baseline is not the scheduled stereo tone")
        print("NATIVE_FX_BASELINE_LATENCY rate=\(rate) target=\(target) effect=\(kind) frames=\(latency)")
        try tick()
        let targetID: UUID? = target == "master" ? nil : target == "group" ? group.id : target == "item" ? track.clips[0].id : track.id
        var settings = NativeFXSettings()
        for stage in 0..<9 {
            switch stage {
            case 1: settings.appendNative(kind)
            case 2, 5: settings.setEnabled(kind, enabled: false)
            case 3, 6: settings.setEnabled(kind, enabled: true)
            case 4:
                switch kind {
                case "EQ": settings.bands = [EQBand(frequency: 1000)]; settings.bands[0].gain = -6
                case "Compressor": settings.threshold = 0; settings.ratio = 1; settings.makeup = -6
                case "Limiter": settings.limiterParameters.ceiling = -24; settings.limiterParameters.inputGain = 12
                case "Delay": settings.delayTime = 0.06; settings.delayMix = 30; settings.feedback = 30
                case "Reverb": settings.reverbRoom = 2; settings.reverbDecay = 0.4; settings.reverbMix = 30
                case "Pitch": settings.pitchSemitones = 3
                default: break
                }
            case 7: settings = NativeFXSettings()
            case 8: settings.appendNative(kind); settings.appendNative(kind)
            default: break
            }
            switch target {
            case "master": state.project.masterFX = settings
            case "group": state.project.songs[0].tracks[0].fx = settings
            case "item": state.project.songs[0].tracks[1].clips[0].fx = settings
            default: state.project.songs[0].tracks[1].fx = settings
            }
            audio.previewFX(targetID, settings: settings)
            revision += 1; try tick()
            var rendered = 0, sumSquares = 0.0, sampleCount = 0, largestPeak: Float = 0, dryError: Float = 0
            var dropouts: [String] = []
            let dry = [0, 2, 5, 7].contains(stage)
            // TimePitch legitimately primes its transform when enabling a
            // nonzero shift. It must then sustain every variable-sized block.
            let pitchPriming = kind == "Pitch" && [4, 6].contains(stage) ? Int(rate * 0.15) : 0
            for block in 0..<72 {
                let count = [64, 128, 256, 512, 1024, 2048][block % 6]
                let firstFrame = Int(engine.manualRenderingSampleTime)
                let result = try engine.renderOffline(AVAudioFrameCount(count), to: buffer)
                precondition(result == .success, "\(kind) stage \(stage): render status \(result)")
                for ch in 0..<2 {
                    var blockEnergy = 0.0
                    for n in 0..<Int(buffer.frameLength) {
                        let value = buffer.floatChannelData![ch][n]
                        precondition(value.isFinite, "\(kind) stage \(stage): non-finite PCM")
                        largestPeak = max(largestPeak, abs(value))
                        precondition(abs(value) < 0.15, "\(kind) stage \(stage): unexpected overshoot \(value)")
                        blockEnergy += Double(value * value)
                        if dry && rendered > Int(rate * (kind == "Limiter" ? 0.8 : 0.25)) {
                            dryError = max(dryError, abs(value - sample(ch, firstFrame + n - latency)))
                        }
                    }
                    if rendered > pitchPriming {
                        if blockEnergy / Double(count) <= 0.00000025 { dropouts.append("block \(block) ch\(ch)") }
                    }
                    sumSquares += blockEnergy; sampleCount += count
                }
                rendered += count; try tick()
            }
            precondition(!dry || dryError < 0.0001,
                         "\(kind) stage \(stage): bypass/removal changed scheduled PCM, error=\(dryError)")
            print("NATIVE_FX_PLAYBACK_STAGE_OK rate=\(rate) target=\(target) effect=\(kind) stage=\(stage) peak=\(largestPeak) rms=\(sqrt(sumSquares / Double(sampleCount))) dryError=\(dryError)")
            precondition(dropouts.isEmpty, "\(kind) stage \(stage): audio dropouts: \(dropouts)")
        }
        print("NATIVE_FX_LIVE_INSERT_EDIT_BYPASS_REMOVE_DUPLICATE_VARIABLE_BUFFERS_OK rate=\(rate) target=\(target) effect=\(kind)")
    }
    }
}
try MainActor.assumeIsolated { try checkNativeFXPlayback() }
