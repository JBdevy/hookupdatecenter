import Foundation
import AVFoundation
import Darwin
setbuf(stdout, nil)

final class JumpCapture: @unchecked Sendable {
    let lock = NSLock()
    var samples: [(UInt64, Double, [Float])] = []
    func append(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
        guard let data = buffer.floatChannelData else { return }
        let values = Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        lock.lock(); samples.append((time.hostTime, buffer.format.sampleRate, values)); lock.unlock()
    }
    func peak(from host: UInt64, through seconds: Double) -> Float {
        lock.lock(); defer { lock.unlock() }
        var peak: Float = 0
        for (base, rate, values) in samples {
            let offset = Double(Int64(bitPattern: base &- host)) * AVAudioTime.seconds(forHostTime: 1)
            for (i, value) in values.enumerated() {
                let t = offset + Double(i) / rate
                if t >= 0 && t < seconds { peak = max(peak, abs(value)) }
            }
        }
        return peak
    }
    func onset(after host: UInt64) -> Double? {
        lock.lock(); defer { lock.unlock() }
        for (base, rate, values) in samples {
            let offset = Double(Int64(bitPattern: base &- host)) * AVAudioTime.seconds(forHostTime: 1)
            for (i, value) in values.enumerated() where abs(value) > 0.02 {
                let t = offset + Double(i) / rate
                if t >= -0.02 { return t }
            }
        }
        return nil
    }
}
@MainActor func field(_ name: String, _ value: Any) -> Any? { Mirror(reflecting: value).children.first { $0.label == name }?.value }
@MainActor func run() async throws {
    let settings = MetronomeSettings.shared
    let old = (settings.enabled, settings.preset, settings.gainA, settings.gainB)
    defer { settings.enabled = old.0; settings.preset = old.1; settings.gainA = old.2; settings.gainB = old.3 }
    settings.enabled = true; settings.preset = "Digital"; settings.gainA = 0; settings.gainB = 0
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 2))!
    buffer.frameLength = buffer.frameCapacity
    for c in 0..<2 { for i in 0..<Int(buffer.frameLength) {
        let t = Double(i) / rate
        buffer.floatChannelData![c][i] = (t < 0.01 || (t >= 0.5 && t < 0.51)) ? 0.5 : 0
    } }
    for (mode, lateTick, pitched, shortAttack) in [("queue", false, false, true), ("section", true, false, false), ("loop", true, false, false), ("shortLoop", true, false, false), ("queue", true, true, false), ("idleQueue", false, false, false)] {
        // An eight-sample attack detects a ramp that destroys the file's first transient.
        if shortAttack {
            for c in 0..<2 { for i in 8..<Int(rate * 0.01) { buffer.floatChannelData![c][i] = 0 } }
        } else {
            for c in 0..<2 { for i in 0..<Int(rate * 0.01) { buffer.floatChannelData![c][i] = 0.5 } }
        }
        do { let file = try AVAudioFile(forWriting: directory.appendingPathComponent("impulses.wav"), settings: format.settings); try file.write(from: buffer) }
        let idleQueue = mode == "idleQueue"
        let isLoop = mode == "loop" || mode == "shortLoop"
        let audio = StemAudioPlayback(engine: AVAudioEngine(), realtime: true)
        audio.open(directory: directory)
        defer { audio.prepareForClosing() }
        var project = Project.empty(name: "Jump transients")
        project.songs[0].duration = idleQueue ? 14 : 6; project.songs[0].bpm = 120
        let first = Part(id: UUID(), name: "Outgoing", startTime: 0, endTime: idleQueue ? 8.83 : 1.83)
        var next = Part(id: UUID(), name: "Incoming", startTime: idleQueue ? 12 : 4, endTime: idleQueue ? 14 : mode == "shortLoop" ? 4.43 : mode == "loop" ? 5.83 : 6)
        if isLoop { next.totalLoop = true }
        project.songs[0].parts = [first, next]
        var track = Track(id: UUID(), name: "Impulse", role: .other)
        track.clips = [AudioClip(id: UUID(), name: "Transient", startTime: next.startTime, duration: 2, audioFile: AudioFile(path: "impulses.wav"))]
        track.clips[0].pitchSemitones = pitched ? 2 : 0
        let trackCount = pitched ? 24 : 1
        project.songs[0].tracks = (0..<trackCount).map { _ in
            var copy = track; copy.id = UUID(); copy.clips[0].id = UUID(); copy.volume = 1 / Double(trackCount); return copy
        }
        var nativeClick = Track(id: UUID(), name: "Click", role: TrackRole(rawValue: TrackKind.click.rawValue)); nativeClick.volume = 0; nativeClick.clickSound = AudioFile(path: "impulses.wav")
        project.songs[0].tracks.append(nativeClick)
        project.insertClickItems(track: nativeClick.id)
        let core = JarasCoreBridge(); try core.load(projectData: JSONEncoder().encode(project))
        func snapshot() throws -> ShowSnapshot { try JSONDecoder().decode(ShowSnapshot.self, from: core.snapshot()) }
        if idleQueue { try core.execute(command: "editSeek", target: nil, value: next.startTime) }
        try audio.update(snapshot(), revision: 1)
        // Preparing another song and then playing elsewhere leaves its silent
        // voice pooled behind a render gate for several seconds. Mixed sample
        // rates used to revive it with a stale host clock and miss this attack.
        if idleQueue { try await Task.sleep(nanoseconds: 2_000_000_000) }
        let live = field("engine", audio) as! AVAudioEngine; live.mainMixerNode.outputVolume = 0
        let click = field("metronomeRoute", audio) as! AVAudioUnitEffect
        let master = field("masterBus", audio) as! AVAudioMixerNode
        let clickCapture = JumpCapture(), stemCapture = JumpCapture(), nativeCapture = JumpCapture()
        let native = (field("clickGenerators", audio) as! [JarasMetronomeGenerator])[0].node
        native.installTap(onBus: 0, bufferSize: 128, format: nil) { b,t in nativeCapture.append(b,t) }
        defer { native.removeTap(onBus: 0) }
        click.installTap(onBus: 0, bufferSize: 128, format: nil) { b,t in clickCapture.append(b,t) }
        master.installTap(onBus: 0, bufferSize: 128, format: nil) { b,t in stemCapture.append(b,t) }
        defer { click.removeTap(onBus: 0); master.removeTap(onBus: 0) }
        try core.execute(command: "seek", target: nil, value: mode == "shortLoop" ? 4.17 : isLoop ? 4.7 : 0.7)
        try core.execute(command: "play", target: nil, value: 0)
        if !isLoop { try core.execute(command: (mode == "queue" || idleQueue) ? "queueRegion" : "queueSection", target: next.id.uuidString, value: 0) }
        try audio.update(snapshot(), revision: 1)
        var last = ProcessInfo.processInfo.systemUptime, host: UInt64 = 0
        let timeout = last + (idleQueue ? 11.5 : 2.5)
        while ProcessInfo.processInfo.systemUptime < timeout {
            try await Task.sleep(nanoseconds: lateTick ? 140_000_000 : 33_333_333)
            let now = ProcessInfo.processInfo.systemUptime; core.advance(now - last); last = now
            try audio.update(snapshot(), revision: 1)
            if let optional = field("preparedJump", audio), let jump = Mirror(reflecting: optional).children.first?.value,
               let value = field("host", jump) as? UInt64, host == 0 { host = value }
        }
        precondition(host != 0)
        print("TRANSIENT_MEASURE mode=\(mode) lateTick=\(lateTick) tracks=\(trackCount) pitch=\(pitched) nativeClick=\(String(describing: nativeCapture.onset(after: host))) rate=\(rate) stemOnset=\(String(describing: stemCapture.onset(after: host))) clickOnset=\(String(describing: clickCapture.onset(after: host))) stemPeak=\(stemCapture.peak(from: host, through: 0.03)) clickPeak=\(clickCapture.peak(from: host, through: 0.03))")
        precondition(stemCapture.peak(from: host, through: 0.03) > 0.1, "Incoming first transient must render at the scheduled boundary")
        precondition(clickCapture.peak(from: host, through: 0.03) > 0.05, "First metronome beat must render at the scheduled boundary")
        precondition(nativeCapture.peak(from: host, through: 0.03) > 0.05, "Click track must preserve its first beat as well")
    }

}
Task { @MainActor in do { try await run(); exit(0) } catch { print(error); exit(1) } }
dispatchMain()
