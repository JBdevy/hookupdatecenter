import Foundation
import AVFoundation
import Darwin
setbuf(stdout, nil)
final class ClickCapture: @unchecked Sendable {
    let lock = NSLock()
    var peak: Float = 0
    func append(_ b: AVAudioPCMBuffer) {
        guard let data = b.floatChannelData else { return }
        var value: Float = 0
        for i in 0..<Int(b.frameLength) { value = max(value, abs(data[0][i])) }
        lock.lock(); peak = max(peak, value); lock.unlock()
    }
    func take() -> Float { lock.lock(); defer { lock.unlock() }; let result = peak; peak = 0; return result }
}
@MainActor func run() async throws {
    let settings = MetronomeSettings.shared
    let previous = (settings.enabled, settings.preset, settings.gainA, settings.gainB, settings.output)
    defer { settings.enabled = previous.0; settings.preset = previous.1; settings.gainA = previous.2; settings.gainB = previous.3; settings.output = previous.4 }
    settings.output = .stereo; settings.enabled = true; settings.preset = "Digital"; settings.gainA = -1; settings.gainB = -1
    let audio = StemAudioPlayback(engine: AVAudioEngine(), realtime: true)
    audio.open(directory: ProcessInfo.processInfo.environment["JARAS_CLICK_PROJECT"] == nil ? FileManager.default.temporaryDirectory : URL(fileURLWithPath: ProcessInfo.processInfo.environment["JARAS_CLICK_DIRECTORY"] ?? NSTemporaryDirectory()))
    defer { audio.prepareForClosing() }
    var project = Project.empty(name: "Click test")
    project.songs[0].parts = [Part(id: UUID(), name: "Test", startTime: 0, endTime: 10)]
    if let path = ProcessInfo.processInfo.environment["JARAS_CLICK_PROJECT"] {
        project = try JSONDecoder().decode(Project.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        for s in project.songs.indices { for t in project.songs[s].tracks.indices {
            project.songs[s].tracks[t].volume = 0
            project.songs[s].tracks[t].clips = []
            project.songs[s].tracks[t].fx = nil
        } }
    }
    var snapshot = ShowSnapshot(project: project, transport: TransportState(playing: false, songId: project.songs[0].id, position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    try audio.update(snapshot, revision: 1)
    let members = Mirror(reflecting: audio).children
    let liveEngine = members.first { $0.label == "engine" }!.value as! AVAudioEngine
    let directOutput = members.first { $0.label == "metronomeRoute" }!.value as! AVAudioUnitEffect
    liveEngine.mainMixerNode.outputVolume = 0
    let capture = ClickCapture()
    directOutput.installTap(onBus: 0, bufferSize: 512, format: nil) { buffer, _ in capture.append(buffer) }
    defer { directOutput.removeTap(onBus: 0) }
    for attempt in 0..<2 {
        snapshot.transport.playing = true; snapshot.transport.position = 60
        for tick in 0..<90 {
            snapshot.transport.position = 60 + Double(tick) / 60
            try audio.update(snapshot, revision: 1)
            try await Task.sleep(nanoseconds: 16_666_667)
        }
        let peak = capture.take()
        print("CLICK_LIVE_PEAK attempt=\(attempt) peak=\(peak)")
        precondition(peak > 0.1, "Metronome must reach its direct hardware route")
        settings.enabled = false
        try await Task.sleep(nanoseconds: 100_000_000)
        _ = capture.take()
        // Keep the transport running: switching off the click must silence it
        // independently of Play/Stop and all later clock updates.
        for tick in 0..<60 {
            snapshot.transport.position = 61.6 + Double(tick) / 60
            try audio.update(snapshot, revision: 1)
            try await Task.sleep(nanoseconds: 16_666_667)
        }
        let offPeak = capture.take()
        print("CLICK_DISABLED_PEAK \(offPeak)")
        precondition(offPeak < 0.00001, "Disabled click must remain silent while transport runs")
        settings.enabled = true
        snapshot.transport.playing = false
        try audio.update(snapshot, revision: 1)
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = capture.take()
    }
}
Task { @MainActor in do { try await run(); exit(0) } catch { print(error); exit(1) } }
dispatchMain()
