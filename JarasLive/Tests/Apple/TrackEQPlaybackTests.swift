import Foundation
import AVFoundation

@MainActor func checkTrackEQ() throws {
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 20))!
    pcm.frameLength = pcm.frameCapacity
    for ch in 0..<2 { pcm.floatChannelData![ch].initialize(repeating: 0, count: Int(pcm.frameLength)) }
    for ch in 0..<2 { for n in 0..<Int(pcm.frameLength) {
        pcm.floatChannelData![ch][n] = Float(0.3 * sin(Double(n) * 2 * .pi * 1000 / rate))
    } }
    try AVAudioFile(forWriting: folder.appendingPathComponent("tone.wav"), settings: format.settings).write(from: pcm)
    var p = Project.empty(name: "EQ playback")
    let group = Track(id: UUID(), name: "Group", role: .other)
    var track = Track(id: UUID(), name: "Track", role: .other)
    track.parentTrackID = group.id; track.outputs = [.masterGroup]
    track.clips = [AudioClip(id: UUID(), name: "Tone", startTime: 0, duration: 20, audioFile: AudioFile(path: "tone.wav"))]
    p.songs[0].tracks = [group,track]
    var time = p.songs[0].projectTime; time.timebase = .free; p.songs[0].timeSettings = time
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let audio = StemAudioPlayback(engine: engine, realtime: false)
    defer { audio.prepareForClosing() }
    audio.open(directory: folder)
    var state = ShowSnapshot(project: p, transport: TransportState(playing: true, songId: p.songs[0].id,
        position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    try audio.update(state, revision: 1)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    var settings = NativeFXSettings(), revision: UInt64 = 1
    func advanceTransport() throws {
        state.transport.position = Double(engine.manualRenderingSampleTime) / rate
        try audio.update(state, revision: revision)
    }
    // Publish the sample clock each block, as the transport does in playback.
    // Skipping ticks simulates a Seek and intentionally triggers its fade-in.
    for _ in 0..<16 {
        let result = try engine.renderOffline(512,to:buffer); precondition(result == .success)
        try advanceTransport()
    }
    for stage in 0..<4 {
        if stage == 1 { settings.appendNative("EQ") }
        if stage == 2 { settings.eqEnabled = false }
        if stage == 3 { settings = NativeFXSettings() }
        state.project.songs[0].tracks[1].fx = settings
        audio.previewFX(track.id, settings: settings)
        revision += 1
        state.transport.position = Double(engine.manualRenderingSampleTime) / rate
        try audio.update(state, revision: revision)
        for blockSize in [64,128,512] {
            for block in 0..<64 {
                let result = try engine.renderOffline(AVAudioFrameCount(blockSize),to:buffer)
                precondition(result == .success)
                let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
                let peak = samples.map { abs($0) }.max() ?? 0
                let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
                precondition(peak < 0.34, "EQ clipping in actual track graph: stage=\(stage) block=\(block) peak=\(peak)")
                precondition(rms > 0.18 && rms < 0.24, "EQ dropout in actual track graph: stage=\(stage) block=\(block) rms=\(rms)")
                try advanceTransport()
            }
        }
    }
    print("TRACK_EQ_ACTUAL_PLAYBACK_LIVE_INSERT_BYPASS_REMOVE_PCM_OK rate=\(rate)")
}
try MainActor.assumeIsolated { try checkTrackEQ() }
