import Foundation
import AVFoundation
@MainActor func testPads() throws {
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let audio = StemAudioPlayback(engine: engine, realtime: false)
    defer { audio.prepareForClosing() }
    audio.open(directory: FileManager.default.temporaryDirectory)
    var project = Project.empty(name: "Pads")
    let track = Track(id: UUID(), name: "VINHETAS-FX", role: TrackRole(rawValue: "vinhetas"))
    project.songs[0].tracks = [track]
    let state = ShowSnapshot(project: project, transport: TransportState(playing: false, songId: project.songs[0].id, position: 0,
        queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    try audio.update(state, revision: 1)
    let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 10))!
    input.frameLength = input.frameCapacity
    for channel in 0..<2 { for frame in 0..<Int(input.frameLength) { input.floatChannelData![channel][frame] = 0.025 } }
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    func level() throws -> Float {
        for _ in 0..<12 { let status = try engine.renderOffline(512, to: output); precondition(status == .success) }
        return output.floatChannelData![0][256]
    }
    func expect(_ expected: Float, _ message: String) throws { let value = try level(); precondition(abs(value - expected) < 0.0001, "\(message): \(value)") }
    let meter = audio.meter(for: track.id)
    let first = UUID(), second = UUID()
    try audio.playPad(first, buffer: input, gain: 1, track: track.id, finished: {})
    try expect(0.025, "Pad must sound with stopped transport")
    try audio.update(state, revision: 1)
    precondition(engine.isRunning, "Updating stopped transport paused a sounding pad")
    precondition(meter.levels.x > 0 && meter.levels.y > 0, "VINHETAS-FX meters ignored a sounding pad with stopped transport")
    try audio.playPad(second, buffer: input, gain: 1, track: track.id, finished: {})
    try expect(0.05, "Repeated pad triggers must overlap")
    audio.stopPad(second); try expect(0.025, "Gate release stops only its voice")
    audio.setPadGain(first, gain: 0.5); try expect(0.0125, "Live pad gain")
    audio.stopPad(first); try expect(0, "All pads stopped")
    var capturedState = state
    var effects = NativeFXSettings(); effects.appendNative("Compressor")
    effects.threshold = 0; effects.ratio = 1; effects.makeup = -6
    capturedState.project.songs[0].tracks[0].fx = effects
    capturedState.project.songs[0].tracks[0].volume = 0.5
    try audio.update(capturedState, revision: 2)
    let captureVoice = UUID()
    try audio.playPad(captureVoice, buffer: input, gain: 1, track: track.id, finished: {})
    for (postFX, postFader, expected) in [(false, false, Float(0.025)), (true, false, Float(0.025 * pow(10.0,-6.0/20.0))), (true, true, Float(0.0125 * pow(10.0,-6.0/20.0)))] {
        let ring = JarasCaptureRing(channels: 2, capacity: 65536)
        ring.beginCapture()
        _ = try audio.attachOutputCapture(track.id, postFX: postFX, postFader: postFader, ring: ring)
        for _ in 0..<40 { _ = try engine.renderOffline(512, to: output); Thread.sleep(forTimeInterval: 0.002) }
        audio.detachOutputCapture(track.id)
        var samples = [Float](repeating: 0, count: 131072)
        let frames = samples.withUnsafeMutableBufferPointer { ring.readFrames($0.baseAddress!, maximum: 65536) }
        precondition(frames > 512, "Output recording tap captured no PCM")
        let value = samples[Int(frames - 256) * 2]
        precondition(abs(value-expected)<0.0002, "Output capture FX=\(postFX) fader=\(postFader) got=\(value) expected=\(expected)")
    }
    var removed = capturedState
    removed.project.songs[0].tracks = []
    try audio.update(removed, revision: 3)
    if !engine.isRunning { try engine.start() }
    try expect(0, "Deleting VINHETAS-FX must stop sounding pads")
    var rejected = 0
    for route in [Optional<UUID>.none, Optional(track.id)] {
        try audio.playPad(UUID(), buffer: input, gain: 1, track: route, finished: { rejected += 1 })
        try expect(0, "Missing pad track must never fall back to Master")
    }
    precondition(rejected == 2)
    try audio.update(capturedState, revision: 4)
    if !engine.isRunning { try engine.start() }
    try expect(0, "Recreating a pad track must not resume stopped voices")
    print("VINHETAS_MISSING_ROUTE_AND_TRACK_DELETION_SILENT_OK rate=\(rate)")
    audio.stopPad(captureVoice)
    print("VINHETAS_OUTPUT_CAPTURE_PREFX_POSTFX_POSTFADER_PCM_OK rate=\(rate)")
    print("VINHETAS_STOPPED_TRANSPORT_OVERLAP_GATE_LIVE_GAIN_PCM_OK rate=\(rate)")
}
try MainActor.assumeIsolated { try testPads() }
