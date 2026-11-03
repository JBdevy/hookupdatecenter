import Foundation
import AVFoundation
import Darwin

setbuf(stdout, nil)
UserDefaults.standard.setVolatileDomain(["jaras.metronome.enabled": false], forName: UserDefaults.argumentDomain)

// The hardware callback must keep running while the control thread prepares
// the next song. A single-threaded manual-render test would manufacture clock
// stalls that cannot model queued playback.
final class MobileSyncCapture: @unchecked Sendable {
    let driver: JarasMobileAudioOutput
    let engine: AVAudioEngine
    let format: AVAudioFormat
    let lock = NSLock(), finished = DispatchSemaphore(value: 0)
    var closing = false
    private var rendering = false, discardInFlight = false
    var samples = Array(repeating: [Float](), count: 3)
    init(driver: JarasMobileAudioOutput, engine: AVAudioEngine, format: AVAudioFormat) {
        self.driver = driver; self.engine = engine; self.format = format
    }
    func start() {
        Thread.detachNewThread { [self] in
            let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
            output.frameLength = 256
            let epoch = mach_absolute_time(), rate = format.sampleRate
            var frame: UInt64 = 0
            while true {
                lock.lock(); let stop = closing; lock.unlock()
                if stop { break }
                let deadline = epoch + AVAudioTime.hostTime(forSeconds: Double(frame) / rate)
                let now = mach_absolute_time()
                if deadline > now { Thread.sleep(forTimeInterval: AVAudioTime.seconds(forHostTime: deadline - now)) }
                var stamp = AudioTimeStamp()
                stamp.mHostTime = deadline
                stamp.mSampleTime = Double(engine.manualRenderingSampleTime)
                stamp.mFlags = [.sampleTimeValid, .hostTimeValid]
                var flags = AudioUnitRenderActionFlags()
                lock.lock(); rendering = true; lock.unlock()
                precondition(driver.renderFrames(256, time: &stamp, flags: &flags, buffers: output.mutableAudioBufferList) == noErr)
                let buffers = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
                lock.lock()
                if !discardInFlight {
                    for channel in 0..<3 {
                        let data = buffers[channel * 2].mData!.assumingMemoryBound(to: Float.self)
                        samples[channel] += UnsafeBufferPointer(start: data, count: 256)
                    }
                }
                rendering = false; discardInFlight = false
                lock.unlock()
                frame += 256
            }
            finished.signal()
        }
    }
    func take() -> [[Float]] {
        lock.lock(); defer { lock.unlock() }
        let result = samples; samples = Array(repeating: [], count: 3); return result
    }
    // Stop can arrive halfway through a hardware callback, after one output
    // bus rendered the previous song. Exclude that already-in-flight buffer
    // from the next song's capture without delaying the immediate next Play.
    func beginNextRun() {
        lock.lock(); defer { lock.unlock() }
        samples = Array(repeating: [], count: 3)
        discardInFlight = rendering
    }
    func stop() { lock.lock(); closing = true; lock.unlock(); finished.wait() }
}

@MainActor func verifyMobileQueueSync() throws {
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-queue-sync-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceRates = [44100.0, 48000.0, 96000.0]
    for sourceRate in sourceRates {
        let format = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sourceRate * 2))!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) {
            let phase = (Double(i) / sourceRate).truncatingRemainder(dividingBy: 0.1)
            let value: Float = phase >= 0.03 && phase < 0.04 ? 0.2 : 0
            buffer.floatChannelData![0][i] = value; buffer.floatChannelData![1][i] = -value
        }
        let file = try AVAudioFile(forWriting: directory.appendingPathComponent("\(Int(sourceRate)).wav"), settings: format.settings)
        try file.write(from: buffer)
    }
    let engine = AVAudioEngine(), driver = JarasMobileAudioOutput(engine: engine)
    let format = try driver.configure(withSampleRate: rate, channels: 6)
    let audio = StemAudioPlayback(engine: engine, realtime: true, mobileOutput: driver)
    audio.open(directory: directory)
    defer { driver.stop(); audio.prepareForClosing() }
    var project = Project.empty(name: "Mobile queue sync")
    project.songs[0].duration = 12
    let parts = (0..<3).map { Part(id: UUID(), name: "Song \($0)", startTime: Double($0 * 4), endTime: Double($0 * 4) + 1.2) }
    project.songs[0].parts = parts
    project.songs[0].tracks = sourceRates.enumerated().map { index, sourceRate in
        var track = Track(id: UUID(), name: "\(sourceRate) Hz", role: .other)
        track.outputs = [OutputPatch(firstChannel: index * 2 + 1, channelCount: 2)]
        track.clips = parts.map { AudioClip(id: UUID(), name: "Stem", startTime: $0.startTime, duration: 1.2,
            audioFile: AudioFile(path: "\(Int(sourceRate)).wav")) }
        return track
    }
    let core = JarasCoreBridge(); try core.load(projectData: JSONEncoder().encode(project))
    func snapshot() throws -> ShowSnapshot { try JSONDecoder().decode(ShowSnapshot.self, from: core.snapshot()) }
    func update() throws { try audio.update(snapshot(), revision: 1) }
    func command(_ name: String, _ target: UUID? = nil, _ value: Double = 0) throws {
        try core.execute(command: name, target: target?.uuidString, value: value)
    }
    func sources(head: Int) -> [ObjectIdentifier: Double] {
        func field(_ name: String, _ value: Any) -> Any? { Mirror(reflecting: value).children.first { $0.label == name }?.value }
        guard let voices = field("voices", audio) else { return [:] }
        var result: [ObjectIdentifier: Double] = [:]
        for entry in Mirror(reflecting: voices).children {
            let pair = Array(Mirror(reflecting: entry.value).children)
            guard pair.count == 2, field("head", pair[0].value) as? Int == head,
                  let source = field("prepared", pair[1].value) as? JarasPreparedClip else { continue }
            result[ObjectIdentifier(source)] = source.sourcePosition
        }
        return result
    }
    try update()
    let capture = MobileSyncCapture(driver: driver, engine: engine, format: format)
    capture.start()
    defer { capture.stop() }
    func render(seconds: Double, advancing: Bool = true) throws {
        var previous = ProcessInfo.processInfo.systemUptime
        let end = previous + seconds
        while ProcessInfo.processInfo.systemUptime < end {
            Thread.sleep(forTimeInterval: 0.02)
            let now = ProcessInfo.processInfo.systemUptime
            if advancing { core.advance(now - previous) }
            previous = now
            try update()
        }
    }
    func check(_ label: String) {
        let captured = capture.take()
        let edges = captured.map { values in
            values.indices.dropFirst().filter { values[$0 - 1] <= 0.08 && values[$0] > 0.08 }
        }
        precondition(edges.allSatisfy { $0.count >= 3 }, "Missing audio in \(label): \(edges.map(\.count))")
        // A capture can start/end inside an attack: the small SRC group delay
        // can put that edge outside only one channel's captured window. Match
        // every interior attack in BOTH directions, so missing/extra pulses or
        // a full-block shift still fail without counting a clipped endpoint.
        let margin = Int(ceil(rate * 0.001))
        var drift = 0
        for channel in edges.indices {
            for edge in edges[channel] where edge >= margin && edge < captured[channel].count - margin {
                for other in edges.indices where other != channel {
                    drift = max(drift, edges[other].map { abs($0 - edge) }.min()!)
                }
            }
        }
        // Different native SRC filters have fractional/group delay at a pulse
        // edge. Bound that to half a millisecond; never accept a shifted block
        // or accumulated timing error between files.
        if drift > Int(ceil(rate * 0.0005)) {
            print("MOBILE_QUEUE_EDGES \(label) frames=\(captured[0].count) edges=\(edges)")
            for channel in captured.indices {
                let data = captured[channel].withUnsafeBytes { Data($0) }
                try? data.write(to: URL(fileURLWithPath: "/tmp/catlive-mobile-sync-failure-\(channel).f32"))
            }
        }
        precondition(drift <= Int(ceil(rate * 0.0005)), "Desynchronized stems in \(label): \(drift) samples")
        print("MOBILE_QUEUE_SYNC rate=\(rate) \(label) attacks=\(edges[0].count) maxSpread=\(drift) samples")
        _ = capture.take()
    }
    for repeatIndex in 0..<2 {
        try command("stopAll"); try update()
        try render(seconds: 0.04, advancing: false)
        _ = capture.take()
        try command("selectRegion", parts[0].id); try command("play"); try update()
        try render(seconds: 0.42)
        check("cold/reused Play \(repeatIndex)")
        try command("stopAll"); try update()
        capture.beginNextRun()
        try command("selectRegion", parts[1].id); try command("play"); try update()
        try command("queueRegion", parts[2].id); try update()
        try render(seconds: 1.75)
        let afterQueue = try snapshot()
        precondition(afterQueue.transport.position >= parts[2].startTime, "Queue did not change region")
        check("immediate other song and queue \(repeatIndex)")
        try command("stopAll"); try update()
    }
    try command("selectRegion", parts[0].id); try command("play"); try update()
    try render(seconds: 0.3)
    try command("queueRegion", parts[1].id); try command("subPlay"); try update()
    try render(seconds: 0.35)
    let prior = try snapshot().transport.subPlayPromotion ?? 0
    let secondary = sources(head: 1)
    try command("stop"); try update() // Promote the running secondary head.
    let promoted = try snapshot()
    precondition(promoted.transport.playing && !promoted.transport.subPlay.playing &&
                 (promoted.transport.subPlayPromotion ?? 0) != prior, "Subplay was not promoted")
    let main = sources(head: 0)
    precondition(secondary.count == 3 && Set(main.keys) == Set(secondary.keys), "Promotion replaced the running sources")
    precondition(main.allSatisfy { $0.value >= secondary[$0.key]! }, "Promotion rewound an incoming stem")
    // Finish the hardware callback that was already in flight when Stop was
    // pressed before taking a new capture window for the promoted head.
    try render(seconds: 0.02)
    _ = capture.take()
    try render(seconds: 0.45)
    check("Subplay promotion preserves the running sources")
    try command("stopAll"); try update()
}
try MainActor.assumeIsolated { try verifyMobileQueueSync() }
