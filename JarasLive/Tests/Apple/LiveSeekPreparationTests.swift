import AVFoundation
import Darwin
import Foundation
import ObjectiveC

// CATLIVE_EXPORT_TEST_SOURCE=Tests/Apple/LiveSeekPreparationTests.swift bash scripts/test-offline-export.sh
// Manual render output keeps the fixture independent of the selected device.
private typealias PCMRead = @convention(c) (AVAudioFile, Selector, AVAudioPCMBuffer, AVAudioFrameCount, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
private let mainQueue = DispatchSpecificKey<Bool>()
private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var main = 0, background = 0
    func record() {
        lock.lock()
        if DispatchQueue.getSpecific(key: mainQueue) != nil { main += 1 } else { background += 1 }
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.003)
    }
    func counts() -> (main: Int, background: Int) {
        lock.lock(); defer { lock.unlock() }
        return (main, background)
    }
}

@MainActor private func run() async throws {
    setbuf(stdout, nil)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-seek-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000 * 5)!
    pcm.frameLength = pcm.frameCapacity
    let count = 8
    var project = Project.empty(name: "Live seek")
    var tracks = (0..<count).map { Track(id: UUID(), name: "Stem \($0)", role: .other) }
    for (index, start) in [0, 30, 60].enumerated() {
        let value: Float = [0.01, -0.02, 0.03][index]
        for channel in 0..<2 { pcm.floatChannelData![channel].initialize(repeating: value, count: Int(pcm.frameLength)) }
        let template = directory.appendingPathComponent("template-\(start).wav")
        try AVAudioFile(forWriting: template, settings: format.settings).write(from: pcm)
        for i in tracks.indices {
            let name = "seek-stem-\(i)-\(start).wav"
            try FileManager.default.copyItem(at: template, to: directory.appendingPathComponent(name))
            tracks[i].clips.append(AudioClip(id: UUID(), name: name, startTime: Double(start), duration: 5, audioFile: AudioFile(path: name)))
        }
    }
    project.songs[0].tracks = tracks; project.songs[0].duration = 65
    let counter = ReadCounter()
    let selector = NSSelectorFromString("readIntoBuffer:frameCount:error:")
    let method = class_getInstanceMethod(AVAudioFile.self, selector)!, original = method_getImplementation(method)
    let read = unsafeBitCast(original, to: PCMRead.self)
    let block: @convention(block) (AVAudioFile, AVAudioPCMBuffer, AVAudioFrameCount, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool = { file, buffer, frames, error in
        if file.url.lastPathComponent.hasPrefix("seek-stem-") { counter.record() }
        return read(file, selector, buffer, frames, error)
    }
    let replacement = imp_implementationWithBlock(block)
    method_setImplementation(method, replacement)
    defer { method_setImplementation(method, original); imp_removeBlock(replacement) }

    let engine = AVAudioEngine(), driver = JarasMobileAudioOutput(engine: engine)
    _ = try driver.configure(withSampleRate: 48000, channels: 2)
    let audio = StemAudioPlayback(engine: engine, realtime: true, mobileOutput: driver)
    audio.open(directory: directory)
    defer { driver.stop(); audio.prepareForClosing() }
    var state = ShowSnapshot(project: project, transport: TransportState(playing: false, songId: project.songs[0].id, position: 0.5, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 0)))
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    output.frameLength = 512
    func render() -> Float {
        var time = AudioTimeStamp(), flags = AudioUnitRenderActionFlags()
        time.mSampleTime = Double(engine.manualRenderingSampleTime); time.mHostTime = mach_absolute_time()
        time.mFlags = [.sampleTimeValid, .hostTimeValid]
        precondition(driver.renderFrames(512, time: &time, flags: &flags, buffers: output.mutableAudioBufferList) == noErr)
        return output.floatChannelData![0][511]
    }
    func outputSettled() async throws -> Float {
        var sample: Float = 0
        for _ in 0..<18 { sample = render(); try await Task.sleep(nanoseconds: 10_666_667) }
        return sample
    }
    try audio.update(state, revision: 1)
    if let ready = try audio.pendingPlaybackPreparation(state, revision: 1) { await ready.value }
    let playbackStart = ProcessInfo.processInfo.systemUptime
    state.transport.playing = true; try audio.update(state, revision: 1, sampledAt: playbackStart)
    let before = try await outputSettled()
    precondition(before > 0.02, "Outgoing stems must be audible")

    let baseline = counter.counts()
    let target = 30.5
    let preparation = audio.pendingSeekPreparation(state, revision: 1, position: target)!
    var ready = false, updates = 0
    Task { @MainActor in await preparation.value; ready = true }
    while !ready {
        let now = ProcessInfo.processInfo.systemUptime
        state.transport.position = 0.5 + now - playbackStart
        try audio.update(state, revision: 1, sampledAt: now)
        let current = render()
        precondition(abs(current - before) < 0.005, "Outgoing PCM changed from \(before) to \(current) on pull \(updates)")
        updates += 1
        try await Task.sleep(nanoseconds: 10_666_667)
    }
    precondition(updates > 1)
    state.transport.position = target
    let seekStart = ProcessInfo.processInfo.systemUptime
    try audio.update(state, revision: 1, sampledAt: seekStart)
    let after = try await outputSettled()
    precondition(abs(after + 2 * before) < 0.01, "Expected destination PCM \(-2 * before), got \(after)")
    let reads = counter.counts()
    precondition(reads.main == baseline.main && reads.background >= baseline.background + count)

    // The core already chose the beat. Keep ticking the outgoing transport
    // while the other head warms, then deliver the core's normal jump serial.
    let lead = Double(ProcessInfo.processInfo.environment["CATLIVE_SEEK_PROBE_LEAD"] ?? "1") ?? 1
    let boundary = target + lead, beatTarget = 60.5
    state.transport.beatSeek = TransportBeatSeek(boundary: boundary, destination: beatTarget)
    var promoted = false, heardDestination = false
    while ProcessInfo.processInfo.systemUptime < seekStart + lead + 0.4 {
        let now = ProcessInfo.processInfo.systemUptime
        let outgoing = target + now - seekStart
        if outgoing >= boundary && !promoted {
            promoted = true
            state.transport.beatSeek = nil
            state.transport.sectionJumpSerial = (state.transport.sectionJumpSerial ?? 0) + 1
        }
        state.transport.position = promoted ? beatTarget + outgoing - boundary : outgoing
        let started = ProcessInfo.processInfo.systemUptime
        try audio.update(state, revision: 1, sampledAt: now)
        let sample = render()
        print("BEAT_PROBE relative=\(outgoing-boundary) frame=\(engine.manualRenderingSampleTime) sample=\(sample) counts=\(counter.counts()) elapsed=\(ProcessInfo.processInfo.systemUptime-started)")
        if outgoing < boundary - 0.1 { precondition(abs(sample - after) < 0.01) }
        if outgoing > boundary + 0.2 { heardDestination = abs(sample - 3 * before) < 0.01 }
        try await Task.sleep(nanoseconds: 10_666_667)
    }
    precondition(heardDestination && counter.counts().main == reads.main,
                 "A queued ruler seek with sufficient lead must meet its beat without foreground PCM reads")

    // Within the normal 150 ms timestamp tolerance, an explicit seek must
    // still replace the head at the exact new source position.
    let epoch = ProcessInfo.processInfo.systemUptime
    try audio.update(state, revision: 1, sampledAt: epoch)
    let nearby = state.transport.position - 0.045
    let nearPreparation = audio.pendingSeekPreparation(state, revision: 1, position: nearby)
    await nearPreparation?.value
    state.transport.position = nearby
    try audio.update(state, revision: 1, sampledAt: epoch)
    let audibleCursor = audio.presentationPosition(head: 0, sampledAt: ProcessInfo.processInfo.systemUptime)!
    precondition(abs(audibleCursor - nearby) < 0.02)

    let canceled = audio.pendingSeekPreparation(state, revision: 1, position: 2.0)!
    try await Task.sleep(nanoseconds: 1_000_000)
    state.transport.playing = false
    try audio.update(state, revision: 1)
    await canceled.value
    precondition(canceled.isCancelled)
    let stopped = try await outputSettled()
    precondition(abs(stopped) < 0.001, "A stopped destination must never resume on completion")
    print("LIVE_SEEK_PCM_OFF_MAIN_OUTGOING_PRESERVED_DESTINATION_CORRECT_STOP_OK stems=\(count) heartbeats=\(updates)")
}

DispatchQueue.main.setSpecific(key: mainQueue, value: true)
Task { @MainActor in do { try await run(); exit(0) } catch { print(error); exit(1) } }
dispatchMain()

