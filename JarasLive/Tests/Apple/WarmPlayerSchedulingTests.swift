import AVFoundation
import Foundation

// Real-device scheduling regression: the master is muted, and an upstream tap
// verifies that already-running silent players start together at a shared host time.
final class Capture: @unchecked Sendable {
    let lock = NSLock()
    var left: [Float] = []
    var right: [Float] = []
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        lock.lock(); defer { lock.unlock() }
        left.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
        right.append(contentsOf: UnsafeBufferPointer(start: channels[1], count: Int(buffer.frameLength)))
    }
    func clear() { lock.lock(); left.removeAll(); right.removeAll(); lock.unlock() }
    func verify() {
        lock.lock(); defer { lock.unlock() }
        let a = left.firstIndex(where: { abs($0) > 0.001 })
        let b = right.firstIndex(where: { abs($0) > 0.001 })
        precondition(a != nil && a == b, "Warm players must start on the same sample in both channels")
        precondition((left.max() ?? 0) > 0.1 && (right.max() ?? 0) > 0.1, "All 24 voices must render")
    }
}
let engine = AVAudioEngine(), mix = AVAudioMixerNode()
let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
engine.attach(mix)
engine.connect(mix, to: engine.mainMixerNode, format: format)
engine.mainMixerNode.outputVolume = 0
let players = (0..<24).map { _ in AVAudioPlayerNode() }
for p in players { engine.attach(p); engine.connect(p, to: mix, format: format) }
let capture = Capture()
mix.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, _ in capture.append(buffer) }
try engine.start()
defer { engine.stop(); mix.removeTap(onBus: 0) }
let buffers = players.indices.map { index -> AVAudioPCMBuffer in
    let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
    b.frameLength = 4410
    for c in 0..<2 { for i in 0..<4410 { b.floatChannelData![c][i] = c == index % 2 ? 0.01 : 0 } }
    return b
}
for pass in 0..<3 {
    // This work belongs to idle preparation, before a transport Play command.
    for p in players {
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        silence.frameLength = 256
        for c in 0..<2 { for i in 0..<256 { silence.floatChannelData![c][i] = 0 } }
        p.scheduleBuffer(silence, at: nil, options: .loops)
        p.play()
    }
    Thread.sleep(forTimeInterval: 0.05)
    capture.clear()
    let start = ProcessInfo.processInfo.systemUptime
    let deadline = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.02))
    for (i, p) in players.enumerated() { p.scheduleBuffer(buffers[i], at: deadline, options: .interrupts) }
    let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
    precondition(elapsed < 20, "Scheduling must finish before the common 20 ms deadline: \(elapsed) ms")
    Thread.sleep(forTimeInterval: 0.25)
    capture.verify()
    for p in players { p.stop() }
    print("WARM_24_PLAYERS_SYNC_OK pass=\(pass) schedulingMs=\(elapsed)")
}
