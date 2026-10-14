import Foundation
import AVFoundation

setbuf(stdout, nil)
UserDefaults.standard.setVolatileDomain(["jaras.metronome.enabled": false], forName: UserDefaults.argumentDomain)

@MainActor func runPlaybackSampleEpochTests() throws {
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 8))!
    source.frameLength = source.frameCapacity
    for channel in 0..<2 { for frame in 0..<Int(source.frameLength) {
        source.floatChannelData![channel][frame] = Float(frame % 4096 + 1) / 65536
    } }
    try AVAudioFile(forWriting: directory.appendingPathComponent("epoch.wav"), settings: format.settings).write(from: source)
    var project = Project.empty(name: "Transport sample epochs")
    var track = Track(id: UUID(), name: "Reference", role: .other)
    track.clips = [AudioClip(id: UUID(), name: "Source", startTime: 0, duration: 8, audioFile: AudioFile(path: "epoch.wav"))]
    project.songs[0].tracks = [track]
    var timing = project.songs[0].projectTime; timing.timebase = .free
    project.songs[0].timeSettings = timing
    var state = ShowSnapshot(project: project, transport: TransportState(playing: true,
        songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false),
        subPlay: SubPlayState(playing: false, position: 0)))
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let audio = StemAudioPlayback(engine: engine, realtime: true)
    defer { audio.prepareForClosing() }
    audio.open(directory: directory)
    let epoch = ProcessInfo.processInfo.systemUptime
    let receiptClock = ProcessInfo.processInfo.environment["CATLIVE_TEST_RECEIPT_CLOCK"] == "1"
    func publish(_ sampledAt: Double) throws {
        // Baseline switch reproduces the former receipt-time scheduling exactly.
        if receiptClock { try audio.update(state, revision: 1) }
        else { try audio.update(state, revision: 1, sampledAt: sampledAt) }
    }
    try publish(epoch)
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    var last: Float = 0
    for _ in 0..<19 {
        let result = try engine.renderOffline(512, to: output)
        precondition(result == .success)
        last = output.floatChannelData![0][511]
    }
    precondition(last > 0)
    func verify(_ name: String) throws {
        let next = Int((last * 65536).rounded()) % 4096
        let result = try engine.renderOffline(512, to: output)
        precondition(result == .success)
        for frame in 0..<512 {
            let expected = Float((next + frame) % 4096 + 1) / 65536
            precondition(abs(output.floatChannelData![0][frame] - expected) < 0.00001,
                         "\(name) restarted the source at sample \(frame)")
        }
        last = output.floatChannelData![0][511]
    }
    Thread.sleep(forTimeInterval: 0.25)
    try publish(epoch)
    try verify("Delayed edit at the same transport epoch")
    state.transport.position = 0.25
    try publish(epoch + 0.25)
    try verify("Next timer tick after delayed edit")
    print("PLAYBACK_DELAYED_EDIT_AND_NEXT_TICK_PRESERVE_SOURCE_PCM_OK rate=\(rate)")
}
try MainActor.assumeIsolated { try runPlaybackSampleEpochTests() }
