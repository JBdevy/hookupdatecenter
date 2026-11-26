import Foundation
import AVFoundation
import Darwin
setbuf(stdout, nil)
UserDefaults.standard.setVolatileDomain(["jaras.metronome.enabled": false], forName: UserDefaults.argumentDomain)
@MainActor func verifyTransportFadeout() throws {
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fadeout-pcm-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 24))!
    source.frameLength = source.frameCapacity
    for ch in 0..<2 { source.floatChannelData![ch].update(repeating: 0.08, count: Int(source.frameLength)) }
    do { let file = try AVAudioFile(forWriting: directory.appendingPathComponent("source.wav"), settings: format.settings); try file.write(from: source) }
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    let audio = StemAudioPlayback(engine: engine, realtime: false)
    audio.open(directory: directory); defer { audio.prepareForClosing() }
    var project = Project.empty(name: "Fadeout PCM")
    var selected = Track(id: UUID(), name: "Fade", role: .other), other = Track(id: UUID(), name: "Keep", role: .other)
    selected.pan = -1; other.pan = 1; other.volume = 0.5
    for which in 0..<2 {
        let item = AudioClip(id: UUID(), name: "Tone", startTime: 0, duration: 24, audioFile: AudioFile(path: "source.wav"))
        if which == 0 { selected.clips = [item] } else { other.clips = [item] }
    }
    // A populated insert chain must fade together with the dry source.
    var fx = NativeFXSettings(); fx.inserted = ["Delay"]; fx.delayEnabled = true; fx.delayMix = 20; fx.feedback = 20; fx.delayTime = 0.05
    selected.fx = fx
    project.songs[0].tracks = [selected, other]; project.songs[0].duration = 24
    var timing = project.songs[0].projectTime; timing.timebase = .free; project.songs[0].timeSettings = timing
    var snapshot = ShowSnapshot(project: project, transport: TransportState(playing: true, songId: project.songs[0].id,
        position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    try audio.update(snapshot, revision: 1)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    func render(_ frames: AVAudioFrameCount = 512) throws {
        let status = try engine.renderOffline(frames, to: buffer)
        precondition(status == .success)
    }
    for _ in 0..<Int(rate * 3 / 512) { try render() }
    print("FADEOUT_PCM_BASELINE_READY")
    let baseline = Double(buffer.floatChannelData![0][0]), unchanged = Double(buffer.floatChannelData![1][0])
    precondition(baseline > 0.02 && unchanged > 0.02)
    let nodes = engine.attachedNodes
    // No control-thread ticks while rendering: the entire ramp uses sample time.
    audio.startTransportFade(tracks: [selected.id], duration: 1)
    let start = engine.manualRenderingSampleTime
    while engine.manualRenderingSampleTime < start + Int64(rate * 1.1) {
        let first = engine.manualRenderingSampleTime
        try render()
        for frame in [0, Int(buffer.frameLength)-1] {
            let t = Double(first - start + Int64(frame)) / rate
            let expected = baseline * max(0, 1 - t)
            precondition(abs(Double(buffer.floatChannelData![0][frame]) - expected) < 0.00004, "Post-FX fade is not sample accurate at \(t)")
            precondition(abs(Double(buffer.floatChannelData![1][frame]) - unchanged) < 0.00002, "Unselected track changed")
        }
    }
    print("FADEOUT_PCM_ENDPOINT_READY")
    precondition(engine.attachedNodes == nodes && snapshot.project == project, "Fade rebuilt the graph or changed project settings")
    audio.setTransportFadeGains([:]); try render()
    precondition(abs(Double(buffer.floatChannelData![0][511]) - baseline) < 0.00004, "Cancel failed to restore original volume")
    audio.startTransportFade(tracks: [selected.id], duration: 5)
    for _ in 0..<Int(rate / 512) { try render() }
    audio.setTransportFadeGains([:]); try render()
    precondition(abs(Double(buffer.floatChannelData![0][511]) - baseline) < 0.00004, "Second command did not cancel while playing")
    audio.startTransportFade(tracks: [selected.id], duration: 1)
    for _ in 0..<Int(rate * 1.1 / 512) { try render() }
    audio.setTransportFadeGains([selected.id: 0])
    snapshot.transport.playing = false
    try audio.update(snapshot, revision: 1)
    audio.setTransportFadeGains([:])
    try engine.start()
    for _ in 0..<16 { try render(); precondition(buffer.floatChannelData![0][511] == 0, "Restore after Stop revived an effect tail") }
    print("FADEOUT_PCM_STOP_SILENT")
    snapshot.transport.playing = true; snapshot.transport.position = 0
    try audio.update(snapshot, revision: 1)
    for _ in 0..<Int(rate * 3 / 512) { try render() }
    precondition(abs(Double(buffer.floatChannelData![0][511]) - baseline) < 0.00004, "Next Play failed to restore original gain")
    print("TRANSPORT_FADEOUT_SAMPLE_CLOCK_POST_FX_CANCEL_STOP_REPLAY_PCM_OK rate=\(rate)")
}
try MainActor.assumeIsolated { try verifyTransportFadeout() }
