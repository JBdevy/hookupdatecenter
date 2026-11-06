import Foundation
import AVFoundation
import Darwin

// No physical output is opened. Exercise the live preparation policy through
// AVAudioEngine's manual renderer, including the Monterey routing policy.
// CATLIVE_EXPORT_TEST_SOURCE=Tests/Apple/PlaybackMediaIsolationTests.swift
// bash scripts/test-offline-export.sh
setbuf(stdout, nil)
UserDefaults.standard.setVolatileDomain(["jaras.metronome.enabled": false], forName: UserDefaults.argumentDomain)

@MainActor private func run() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-isolation-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    func voiceCount(_ audio: StemAudioPlayback) -> Int {
        let voices = Mirror(reflecting: audio).children.first { $0.label == "voices" }!.value
        return Mirror(reflecting: voices).children.count
    }

    for rate in [44100.0, 48000.0] {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        func write(_ name: String, left: Float, right: Float) throws {
            let file = try AVAudioFile(forWriting: root.appendingPathComponent(name), settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 15))!
            buffer.frameLength = buffer.frameCapacity
            buffer.floatChannelData![0].update(repeating: left, count: Int(buffer.frameLength))
            buffer.floatChannelData![1].update(repeating: right, count: Int(buffer.frameLength))
            try file.write(from: buffer)
        }
        try write("left.wav", left: 0.08, right: 0)
        try write("right.wav", left: 0, right: 0.12)

        func fixture() -> ShowSnapshot {
            var project = Project.empty(name: "Unavailable source between valid stems")
            project.songs[0].duration = 15
            project.songs[0].tracks = ["left.wav", "broken.wav", "right.wav"].map { name in
                var track = Track(id: UUID(), name: name, role: .other)
                track.clips = [AudioClip(id: UUID(), name: name, startTime: 0, duration: 15, audioFile: AudioFile(path: name))]
                return track
            }
            return ShowSnapshot(project: project, transport: TransportState(playing: true,
                songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false),
                subPlay: SubPlayState(playing: false, position: 0)))
        }
        func checkPCM(_ engine: AVAudioEngine, left: Float, right: Float) throws {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
            var peaks: [Float] = [0, 0]
            for block in 0..<48 {
                let status = try engine.renderOffline(512, to: buffer)
                precondition(status == .success)
                if block >= 24 {
                    for channel in 0..<2 { for index in 0..<Int(buffer.frameLength) {
                        peaks[channel] = max(peaks[channel], abs(buffer.floatChannelData![channel][index]))
                    } }
                }
            }
            precondition(abs(peaks[0] - left) < 0.00005 && abs(peaks[1] - right) < 0.00005,
                "Valid stems were silenced or changed by another source failure: \(peaks)")
        }

        for legacyRouting in [false, true] {
            for warm in [false, true] {
                try Data("invalid audio container".utf8).write(to: root.appendingPathComponent("broken.wav"))
                let engine = AVAudioEngine()
                try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
                let audio = StemAudioPlayback(engine: engine, realtime: true, pauseForRoutingChanges: legacyRouting)
                audio.open(directory: root)
                defer { audio.prepareForClosing() }
                var reported: [Error] = []
                audio.onError = { reported.append($0) }
                var state = fixture()
                if warm {
                    state.transport.playing = false
                    try audio.update(state, revision: 1)
                    let deadline = Date().addingTimeInterval(5)
                    while reported.isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
                    precondition(reported.count == 1, "Idle preparation must report the source failure once")
                    for _ in 0..<8 {
                        try audio.update(state, revision: 1)
                        await Task.yield()
                    }
                    precondition(reported.count == 1, "Repeated stopped updates must retain the failed-file quarantine")
                }
                state.transport.playing = true
                try audio.update(state, revision: 1)
                precondition(reported.count == 1 && voiceCount(audio) == 2,
                    "A failed stem must not prevent the preceding or following stem from starting")
                try checkPCM(engine, left: 0.08, right: 0.12)
                try audio.update(state, revision: 1)
                precondition(reported.count == 1, "UI updates must not reopen/report failed media every frame")
                state.transport.playing = false
                try audio.update(state, revision: 1)
                try write("broken.wav", left: 0.03, right: 0.03)
                state.transport.playing = true
                try audio.update(state, revision: 2)
                precondition(voiceCount(audio) == 3, "Stop and file repair must permit a fresh reader")
                try checkPCM(engine, left: 0.11, right: 0.15)
                print("PLAYBACK_MEDIA_FAILURE_ISOLATION_PCM_OK rate=\(rate) legacyRouting=\(legacyRouting) warm=\(warm)")
            }
        }

        // Export remains strict, but a failed batch may not leave players
        // registered as active without a queued buffer. Retrying the same
        // snapshot after repairing media must schedule all original stems.
        try Data("invalid audio container".utf8).write(to: root.appendingPathComponent("broken.wav"))
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        let audio = StemAudioPlayback(engine: engine, realtime: false)
        audio.open(directory: root)
        defer { audio.prepareForClosing() }
        let state = fixture()
        do { try audio.update(state, revision: 1); preconditionFailure("Offline export must report incomplete media") }
        catch { precondition(voiceCount(audio) == 0, "Failed preparation retained a silent, unscheduled voice") }
        try write("broken.wav", left: 0.03, right: 0.03)
        try audio.update(state, revision: 1)
        precondition(voiceCount(audio) == 3)
        try checkPCM(engine, left: 0.11, right: 0.15)
        print("PLAYBACK_FAILED_BATCH_ROLLBACK_AND_RETRY_PCM_OK rate=\(rate)")
    }
}

Task { @MainActor in
    do { try await run(); exit(0) }
    catch { print("PLAYBACK_MEDIA_ISOLATION_ERROR", error); exit(1) }
}
dispatchMain()
