import Foundation
import AVFoundation
setbuf(stdout, nil)
UserDefaults.standard.setVolatileDomain(["jaras.metronome.enabled": false], forName: UserDefaults.argumentDomain)

@MainActor func recordingItemSilence() throws {
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 30))!
    source.frameLength = source.frameCapacity
    for ch in 0..<2 { for n in 0..<Int(source.frameLength) { source.floatChannelData![ch][n] = 0.125 } }
    try AVAudioFile(forWriting: directory.appendingPathComponent("existing.wav"), settings: format.settings).write(from: source)
    for realtime in [false, true] {
        var project = Project.empty(name: "Recording item suppression")
        var target = Track(id: UUID(), name: "Recording", role: TrackRole(rawValue: "vinhetas"))
        target.clips = [AudioClip(id: UUID(), name: "Existing", startTime: 0, duration: 30, audioFile: AudioFile(path: "existing.wav"))]
        var other = Track(id: UUID(), name: "Accompaniment", role: .other)
        other.volume = 0.5; other.clips = [AudioClip(id: UUID(), name: "Other", startTime: 0, duration: 30, audioFile: AudioFile(path: "existing.wav"))]
        project.songs[0].tracks = [target, other]
        var timing = project.songs[0].projectTime; timing.timebase = .free; project.songs[0].timeSettings = timing
        var state = ShowSnapshot(project: project, transport: TransportState(playing: true,
            songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false),
            subPlay: SubPlayState(playing: false, position: 0)))
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        let audio = StemAudioPlayback(engine: engine, realtime: realtime)
        audio.open(directory: directory); defer { audio.prepareForClosing() }
        try audio.update(state, revision: 1)
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        func expect(_ expected: Float, _ label: String) throws {
            for _ in 0..<32 {
                let status = try engine.renderOffline(512, to: output)
                precondition(status == .success)
                state.transport.position = Double(engine.manualRenderingSampleTime) / rate
                try audio.update(state, revision: 1)
            }
            let value = output.floatChannelData![0][256]
            precondition(abs(value - expected) < 0.0001, "\(label): got \(value), expected \(expected)")
        }
        try expect(0.1875, "Normal playback")
        audio.setRecordingItemTracks([target.id])
        try expect(0.0625, "Only the recording track's existing item must be silent")
        audio.previewItemGain(target.clips[0].id, gain: 2)
        try expect(0.0625, "Editing gain during recording must not bypass suppression")
        let live = UUID()
        try audio.playPad(live, buffer: source, gain: 0.2, track: target.id, finished: {})
        try expect(0.0875, "Live sound must pass on the recording track")
        let ring = JarasCaptureRing(channels: 2, capacity: 65536)
        ring.beginCapture()
        _ = try audio.attachOutputCapture(target.id, postFX: true, postFader: true, ring: ring)
        for _ in 0..<40 { _ = try engine.renderOffline(512, to: output); Thread.sleep(forTimeInterval: 0.002) }
        audio.detachOutputCapture(target.id); ring.endCapture()
        var captured = [Float](repeating: 0, count: 131072)
        let frames = captured.withUnsafeMutableBufferPointer { ring.readFrames($0.baseAddress!, maximum: 65536) }
        precondition(frames > 512 && abs(captured[Int(frames - 256) * 2] - 0.025) < 0.0001,
                     "The recorded output must contain live sound without the existing item")
        audio.stopPad(live)
        audio.setRecordingItemTracks([])
        try expect(0.3125, "Ending recording restores the existing item with its edited gain")
        audio.previewClipMute(target.clips[0].id, muted: true)
        audio.setRecordingItemTracks([target.id]); audio.setRecordingItemTracks([])
        try expect(0.0625, "Ending recording must preserve a manually muted item")
        audio.setRecordingItemTracks([other.id])
        try expect(0, "Changing the recording target suppresses its items too")
        audio.setRecordingItemTracks([])
        try expect(0.0625, "Other track resumes after recording")
        print("RECORDING_ITEMS_SILENT_LIVE_INPUT_OUTPUT_CAPTURE_RESTORE_MANUAL_MUTE_OK realtime=\(realtime) rate=\(rate)")
    }
}
try MainActor.assumeIsolated { try recordingItemSilence() }
