import AVFoundation
import Darwin
import Foundation
import ObjectiveC

// Block a specific decoder until the UI finishes swapping the project, then
// return a real read error rather than a CancellationError.
private final class BlockedRead {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    var waiting: Bool {
        condition.lock(); defer { condition.unlock() }; return entered
    }
    func failWhenReleased() {
        condition.lock()
        entered = true
        let deadline = Date().addingTimeInterval(8)
        while !released {
            if !condition.wait(until: deadline) {
                precondition(released, "Project replacement waited for the old decoder")
            }
        }
        condition.unlock()
    }
    func release() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
}

@MainActor private func run() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-subplay-media-" + UUID().uuidString)
    let old = root.appendingPathComponent("old"), new = root.appendingPathComponent("new")
    defer { try? FileManager.default.removeItem(at: root) }
    let rate = Double(ProcessInfo.processInfo.environment["JARAS_TEST_SAMPLE_RATE"] ?? "44100")!
    let stereo = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let pcm = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: UInt32(rate * 2))!
    pcm.frameLength = pcm.frameCapacity
    for channel in 0..<2 { pcm.floatChannelData![channel].update(repeating: 0.125, count: Int(pcm.frameLength)) }
    for directory in [old, new] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try AVAudioFile(forWriting: directory.appendingPathComponent("pad.wav"), settings: stereo.settings).write(from: pcm)
    }
    func state() -> ShowSnapshot {
        var project = Project.empty(name: "Subplay")
        var track = Track(id: UUID(), name: "Pad", role: .other)
        track.clips = [AudioClip(id: UUID(), name: "Pad", startTime: 5, duration: 2, audioFile: AudioFile(path: "pad.wav"))]
        project.songs[0].tracks = [track]; project.songs[0].duration = 7
        return ShowSnapshot(project: project, transport: TransportState(playing: true, songId: project.songs[0].id,
            position: 0, queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 5)))
    }
    let engine = AVAudioEngine(), driver = JarasMobileAudioOutput(engine: engine)
    let format = try driver.configure(withSampleRate: rate, channels: 2)
    let audio = StemAudioPlayback(engine: engine, realtime: true, mobileOutput: driver)
    defer { driver.stop(); audio.prepareForClosing() }
    var errors: [String] = []
    audio.onError = { errors.append($0.localizedDescription) }
    let gate = BlockedRead()
    let selector = NSSelectorFromString("readIntoBuffer:frameCount:error:")
    let method = class_getInstanceMethod(AVAudioFile.self, selector)!
    let original = method_getImplementation(method)
    typealias Read = @convention(c) (AVAudioFile, Selector, AVAudioPCMBuffer, AVAudioFrameCount, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
    let read = unsafeBitCast(original, to: Read.self)
    let oldFile = old.appendingPathComponent("pad.wav")
    let replacement: @convention(block) (AVAudioFile, AVAudioPCMBuffer, AVAudioFrameCount, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool = { file, buffer, frames, error in
        if file.url.path == oldFile.path {
            gate.failWhenReleased()
            error?.pointee = NSError(domain: "CatLive.Test", code: 22, userInfo: [NSLocalizedDescriptionKey:"Previous project read failed"])
            return false
        }
        return read(file, selector, buffer, frames, error)
    }
    method_setImplementation(method, imp_implementationWithBlock(replacement))
    defer { gate.release(); method_setImplementation(method, original) }
    let previous = state()
    audio.open(directory: old)
    try audio.update(previous, revision: 1)
    let task = audio.pendingSubplayPreparation(previous, revision: 1)!
    let deadline = Date().addingTimeInterval(3)
    while !gate.waiting && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
    precondition(gate.waiting, "Expected file decoder to block off the main actor")
    audio.open(directory: new)
    var current = state()
    try audio.update(current, revision: 2)
    gate.release()
    await task.value
    if let prep = audio.pendingSubplayPreparation(current, revision: 2) { await prep.value }
    current.transport.subPlay.playing = true
    try audio.update(current, revision: 2)
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    output.frameLength = 512
    var peak: Float = 0
    for _ in 0..<48 {
        var stamp = AudioTimeStamp()
        stamp.mHostTime = mach_absolute_time()
        stamp.mSampleTime = Double(engine.manualRenderingSampleTime)
        stamp.mFlags = [.hostTimeValid, .sampleTimeValid]
        var flags = AudioUnitRenderActionFlags()
        precondition(driver.renderFrames(512, time: &stamp, flags: &flags, buffers: output.mutableAudioBufferList) == noErr)
        for i in 0..<512 { peak = max(peak, abs(output.floatChannelData![0][i])) }
        try await Task.sleep(nanoseconds: UInt64(512e9/rate))
    }
    print("SUBPLAY_PROJECT_SWAP", Int(rate), "errors", errors, "PCM peak", peak)
    precondition(errors.isEmpty && abs(peak - 0.125) < 0.002,
        "A canceled decoder must not report errors to the new project or suppress its healthy file at the same relative path")
}

setbuf(stdout, nil)
Task { @MainActor in
    do { try await run(); exit(0) } catch { print(error); exit(1) }
}
dispatchMain()
