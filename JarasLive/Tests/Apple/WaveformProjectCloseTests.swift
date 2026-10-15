import Foundation
import AVFoundation

extension TimelineAudioWaveform {
    func enqueueCloseProbe(_ url: URL, work: @escaping () -> Bool) {
        enqueue("close-probe", url: url, work: work)
    }
    var acceptingCloseProbe: Bool { acceptsProjectWork() }
}

Task { @MainActor in
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("test.wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    try autoreleasepool {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for channel in 0..<2 {
            for frame in 0..<48_000 { buffer.floatChannelData![channel][frame] = sin(Float(frame) * 0.03) * 0.5 }
        }
        try file.write(from: buffer)
    }
    let cache = TimelineAudioWaveform()
    await cache.preload([url])
    weak var oldHeader = cache.header(url)
    precondition(oldHeader != nil)
    let diskCache = TimelineAudioWaveform.diskCacheURL(url)
    precondition(FileManager.default.fileExists(atPath: diskCache.path))
    await cache.closeProject()
    precondition(oldHeader == nil, "Closing must release pinned project headers and their sources")
    precondition(cache.header(url) == nil, "A hidden outgoing view cannot restart decoding")
    precondition(cache.preparingSourcePaths.isEmpty)
    precondition(FileManager.default.fileExists(atPath: diskCache.path), "Closing only releases memory; peak files survive")
    await cache.preload([url], cachedOnly: true)
    precondition(cache.header(url) != nil, "A later project can reuse its persisted peaks")
    await cache.closeProject()
    let decode = DispatchQueue(label: "test.close.pending-decode")
    let gate = DispatchSemaphore(value: 0), executed = DispatchSemaphore(value: 0)
    decode.async { gate.wait() }
    let pendingCache = TimelineAudioWaveform(worker: decode)
    pendingCache.enqueueCloseProbe(url) { executed.signal(); return true }
    let closing = Task { @MainActor in await pendingCache.closeProject() }
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while pendingCache.acceptingCloseProbe && ProcessInfo.processInfo.systemUptime < deadline { await Task.yield() }
    precondition(!pendingCache.acceptingCloseProbe)
    gate.signal()
    await closing.value
    precondition(executed.wait(timeout: .now()) == .timedOut, "Queued outgoing work must be cancelled before it can refill caches")
    print("WAVEFORM_PROJECT_CLOSE_RELEASES_RAM_REJECTS_HIDDEN_VIEW_WORK_AND_REOPENS_OK")
    exit(0)
}
RunLoop.main.run()
