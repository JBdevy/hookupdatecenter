import Foundation
import AVFoundation
import Darwin
setbuf(stdout, nil)
final class Capture: @unchecked Sendable {
    let lock = NSLock()
    var samples: [Float] = []
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        lock.lock(); defer { lock.unlock() }
        samples += Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }
    func read() -> [Float] { lock.lock(); defer { lock.unlock() }; return samples }
}
@MainActor func run(mode: String) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-seek-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    do {
    let file = try AVAudioFile(forWriting: directory.appendingPathComponent("tone.wav"), settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000 * 5)!
    buffer.frameLength = buffer.frameCapacity
    for c in 0..<2 { for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![c][i] = 0.025 } }
    try file.write(from: buffer)
    }
    let enabled = MetronomeSettings.shared.enabled
    MetronomeSettings.shared.enabled = false
    defer { MetronomeSettings.shared.enabled = enabled }
    let engine = AVAudioEngine()
    let renderer = StemAudioPlayback(engine: engine)
    renderer.open(directory: directory)
    defer { renderer.prepareForClosing() }
    var project = Project.empty(name: "Boundary test")
    var track = Track(id: UUID(), name: "Tone", role: .other)
    track.clips = [AudioClip(id: UUID(), name: "Tone", startTime: 0, duration: 5, sourceOffset: 0, waveform: [], audioFile: AudioFile(path: "tone.wav"))]
    project.songs[0].duration = 5; project.songs[0].tracks = [track]
    project.songs[0].parts = [Part(id: UUID(), name: "Song", startTime: mode == "start" ? 0.2 : 0, endTime: 5)]
    let a = TimelineMarker(id: UUID(), name: "A", position: 0.2, color: 0, section: true)
    let b = TimelineMarker(id: UUID(), name: "B", position: 1, color: 0, section: true)
    let c = TimelineMarker(id: UUID(), name: "C", position: 2, color: 0, section: true)
    let d = TimelineMarker(id: UUID(), name: "D", position: 3, color: 0, section: true)
    project.songs[0].markers = [a,b,c,d]
    var state = ShowSnapshot(project: project, transport: TransportState(sectionJumpSerial: 0, playing: true, songId: project.songs[0].id, position: 0.2, queue: QueueState(), loop: LoopState(enabled: (mode == "loop" || mode == "edit"), start: 0.2, end: 1), subPlay: SubPlayState(playing: false, position: 0)))
    if mode == "seek" || mode == "cancel" { state.transport.queuedSectionMarkerId = c.id }
    if mode == "start" { state.transport.queuedSectionMarkerId = project.songs[0].parts[0].id }
    try renderer.update(state, revision: 1)
    let capture = Capture()
    let rate = engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
    engine.mainMixerNode.installTap(onBus: 0, bufferSize: 256, format: nil) { buffer, _ in capture.append(buffer) }
    defer { engine.mainMixerNode.removeTap(onBus: 0) }
    let start = ProcessInfo.processInfo.systemUptime
    var last = start
    while ProcessInfo.processInfo.systemUptime - start < 4.5 {
        RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 30))
        let now = ProcessInfo.processInfo.systemUptime
        var position = state.transport.position + now - last; last = now
        if (mode == "loop" || mode == "edit"), position >= 1 {
            position = 0.2 + (position - 0.2).truncatingRemainder(dividingBy: 0.8); state.transport.sectionJumpSerial! += 1
        } else if mode == "start", position >= 1 {
            position = 0.2 + position - 1; state.transport.sectionJumpSerial! += 1
        } else if mode == "seek" {
            if state.transport.queuedSectionMarkerId == c.id, position >= 1 {
                position += 1; state.transport.sectionJumpSerial! += 1; state.transport.queuedSectionMarkerId = a.id
            } else if state.transport.queuedSectionMarkerId == a.id, position >= 3 {
                position = 0.2 + position - 3; state.transport.sectionJumpSerial! += 1; state.transport.queuedSectionMarkerId = c.id
            }
        } else if mode == "cancel", position >= 0.5 { state.transport.queuedSectionMarkerId = nil }
        if mode == "edit", now - start > 0.3 {
            renderer.previewItemGain(track.clips[0].id, gain: 0.5)
        }
        state.transport.position = position
        try renderer.update(state, revision: 1)
    }
    let samples = Array(capture.read().dropFirst(Int(rate * 0.35)).dropLast(Int(rate * 0.15)))
    precondition(samples.count > Int(rate * 3), "real device rendered the test")
    var longest = 0, run = 0
    for value in samples {
        run = abs(value) < 0.00005 ? run + 1 : 0
        longest = max(longest, run)
    }
    let silence = Double(longest) / rate
    print("REALTIME_\(mode.uppercased())_MAX_SILENCE_SECONDS=\(silence) RATE=\(rate) JUMPS=\(state.transport.sectionJumpSerial!)")
    precondition(silence < 0.008, "a loop must not add UI/preroll silence")
    if mode == "edit" {
        let later = samples.dropFirst(Int(rate * 0.5))
        precondition((later.map { abs($0) }.max() ?? 1) < 0.014, "prepared voices receive live item gain changes before promotion")
    }
}
try MainActor.assumeIsolated { for mode in ["loop", "seek", "cancel", "edit", "start"] { try run(mode: mode) } }
