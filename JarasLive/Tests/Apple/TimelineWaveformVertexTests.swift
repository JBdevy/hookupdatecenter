import Foundation
import AVFoundation

setbuf(stdout, nil)
for value: Float in [-128, -8, -2, -1, -0.95, -0.0001, 0, 0.0001, 0.7, 1, 2, 8, 128] {
    let restored = WaveformPeakCodec.decode(WaveformPeakCodec.encode(value))
    let bound: Float = abs(value) <= 1 ? 1 / 49152 : abs(value) * 0.00035
    precondition(abs(restored - value) <= bound, "RPKL preserves polarity, quiet detail and floating-point headroom")
}
print("RPKL_SIGNED_16BIT_QUANTIZATION_AND_FLOAT_HEADROOM_OK")
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jaras-vertex-tests-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }

if let fixture = ProcessInfo.processInfo.environment["JARAS_MP3_EOF_FIXTURE"] {
    // Only the disposable copy may acquire a .waveform cache.
    let copy = directory.appendingPathComponent("gapless-tail.mp3")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: copy)
    let audio = try AVAudioFile(forReading: copy)
    let header = TimelineAudioWaveform.Header(rate: audio.processingFormat.sampleRate,
        frames: audio.length, channels: Int(audio.processingFormat.channelCount))
    let source = try WaveformSource.loadOrBuild(copy, header: header)
    let cacheURL = TimelineAudioWaveform.diskCacheURL(copy)
    let persisted = try Data(contentsOf: cacheURL)
    precondition(!persisted.isEmpty)
    let reopened = try WaveformSource.loadOrBuild(copy, header: header)
    let span = 65_536
    let start = max(0, (header.frames / Int64(span)) * Int64(span))
    let before = source.vertices(start: start, step: 256, span: span, key: "tail")
    let after = reopened.vertices(start: start, step: 256, span: span, key: "tail")
    precondition(before.channels == after.channels && !before.channels.isEmpty)
    let persistedAgain = try Data(contentsOf: cacheURL)
    precondition(persistedAgain == persisted,
        "An MP3 tail mismatch must produce a complete reusable disk cache")
    print("MP3_GAPLESS_TAIL_WAVEFORM_BUILD_AND_REOPEN_OK")
}

// All new caches live beneath the canonical project Stems directory.
let projectRoot = directory.appendingPathComponent("Layout")
let nestedAudio = projectRoot.appendingPathComponent("Stems/Batch/Guitar.wav")
precondition(TimelineAudioWaveform.diskCacheURL(nestedAudio) == projectRoot.appendingPathComponent("Stems/WF/Batch/Guitar.wav.waveform"))
precondition(TimelineAudioWaveform.diskCacheURL(directory.appendingPathComponent("source.wav")) == directory.appendingPathComponent("Stems/WF/source.wav.waveform"))
print("WF_INSIDE_STEMS_PRESERVES_SOURCE_SUBDIRECTORIES_OK")

func awaitValue<T>(_ body: () -> T?) -> T {
    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline {
        if let value = body() { return value }
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    fatalError("Timed out waiting for waveform vertices")
}
func createAudio(_ url: URL, rate: Double, frames: Int, amplitude: Float = 0.3) throws -> [[Float]] {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    var channels = Array(repeating: Array(repeating: Float.zero, count: frames), count: 2)
    for frame in 0..<frames {
        channels[0][frame] = Float(sin(Double(frame) * 2 * .pi * 439 / rate)) * amplitude
        channels[1][frame] = frame == 12_345 ? -0.95 : 0
        buffer.floatChannelData![0][frame] = channels[0][frame]
        buffer.floatChannelData![1][frame] = channels[1][frame]
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    return channels
}

extension TimelineAudioWaveform {
    func evictSourcePyramidsForTest() { sources.removeAllObjects() }
}
for rate in [44_100.0, 48_000.0] {
    let url = directory.appendingPathComponent("source-\(Int(rate)).wav")
    let frames = 131_373 // Deliberately cross decoder and pyramid boundaries.
    let original = try createAudio(url, rate: rate, frames: frames)
    let decode = DispatchQueue(label: "jaras.vertices.test.decode")
    let cache = TimelineAudioWaveform(worker: decode)
    let header = awaitValue { cache.header(url) }
    decode.suspend()
    let began = ProcessInfo.processInfo.systemUptime
    let unavailable = cache.vertexDrawing(url, header: header, start: 0, end: 512 / rate, pixelsPerSecond: rate)
    let lookupTime = ProcessInfo.processInfo.systemUptime - began
    decode.resume()
    precondition(!unavailable.complete && unavailable.blocks.isEmpty && lookupTime < 0.05,
                 "a cold GPU lookup must never wait for decode or build paths")

    var completeByStep: [Int: TimelineAudioWaveform.VertexDrawing] = [:]
    for step in [1, 2, 4, 64, 128, 256, 512, 1024, 16_384, 65_536] {
        let scale = rate / Double(step * 2)
        let start = step == 1 ? 12_000 / rate : 0
        let end = step == 1 ? 13_000 / rate : Double(frames) / rate
        let drawing: TimelineAudioWaveform.VertexDrawing = awaitValue {
            let value = cache.vertexDrawing(url, header: header, start: start, end: end, pixelsPerSecond: scale)
            return value.complete ? value : nil
        }
        precondition(drawing.requestedStep == step)
        var peakPresent = false
        for block in drawing.blocks {
            precondition(block.channels.count == 3 && block.step == step)
            precondition(block.end <= frames && block.start < block.end)
            for channel in 0..<3 {
                var previous = -1
                for (pointIndex, point) in block.channels[channel].enumerated() {
                    let frame = Int(block.start) + Int(point.x)
                    precondition((step < 256 ? frame > previous && frame < frames : frame >= previous && frame <= frames),
                                 "every cached level is an ordered source curve")
                    previous = frame
                    if step < 256 {
                        let expected = channel < 2 ? original[channel][frame]
                            : (original[0][frame] + original[1][frame]) * 0.5
                        precondition(abs(point.y + expected) < 0.000001,
                                     "sample-detail vertices preserve exact signed PCM and phase-correct mono")
                    } else {
                        let local = Int(block.channels[channel][pointIndex / 2 * 2].x)
                        let first = Int(block.start) + local / step * step
                        let last = min(frames, first + step)
                        var low = Float.infinity, high = -Float.infinity
                        for index in first..<last {
                            let value = channel < 2 ? original[channel][index]
                                : (original[0][index] + original[1][index]) * 0.5
                            low = min(low, value); high = max(high, value)
                        }
                        precondition(min(abs(point.y + low), abs(point.y + high)) <= 1 / 48000,
                                     "each compact envelope point preserves an actual signed bucket extremum within 16-bit precision")
                    }
                    if channel == 1 && point.y > 0.9 {
                        precondition(step < 256 ? frame == 12_345 : abs(frame - 12_345) <= step); peakPresent = true
                    }
                }
            }
        }
        precondition(peakPresent, "a single-sample transient cannot move or disappear at another resolution")
        let duplicate = cache.vertexDrawing(url, header: header, start: start, end: end, pixelsPerSecond: scale)
        precondition(duplicate.complete && zip(duplicate.blocks, drawing.blocks).allSatisfy { $0 === $1 },
                     "duplicated items and warm transforms must reuse the same immutable block objects")
        completeByStep[step] = drawing
    }
    print("GPU_VERTEX_ORIGINAL_PCM_EXTREMA_CHANNELS_PYRAMID_AND_SHARING_OK rate=\(rate)")

    let seam: TimelineAudioWaveform.VertexDrawing = awaitValue {
        let value = cache.vertexDrawing(url, header: header, start: 0, end: 1536 / rate, pixelsPerSecond: rate)
        return value.complete ? value : nil
    }
    for (a, b) in zip(seam.blocks, seam.blocks.dropFirst()) {
        precondition(a.end == b.start)
        for channel in 0..<3 {
            precondition(a.channels[channel].last!.y == b.channels[channel].first!.y,
                         "adjacent blocks share the exact original boundary sample")
        }
    }
    let fractional = cache.vertexDrawing(url, header: header, start: 500.25 / rate, end: 512.5 / rate, pixelsPerSecond: rate)
    precondition(fractional.complete && fractional.blocks.count == 2,
                 "fractional-sample zoom boundaries need coverage from both neighboring blocks")
    let cacheURL = TimelineAudioWaveform.diskCacheURL(url)
    let persisted = try Data(contentsOf: cacheURL)
    func u64(_ data: Data, _ offset: Int) -> UInt64 { data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) } }
    func u32(_ data: Data, _ offset: Int) -> UInt32 { data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) } }
    precondition(String(data: persisted.prefix(8), encoding: .utf8) == "JARASPK4")
    precondition(u32(persisted, 44) >= 5 && u64(persisted, 48) == 256 && u64(persisted, 72) == 1024,
                 "sparse compact levels have a binary index and reopen without deserializing the entire source")
    precondition(persisted.count < ((frames + 255) / 256) * 3 * 6,
                 "all levels together remain below six bytes per base interval/channel")
    let reopened = TimelineAudioWaveform()
    let reopenedHeader = awaitValue { reopened.header(url) }
    let restored: TimelineAudioWaveform.VertexDrawing = awaitValue {
        let value = reopened.vertexDrawing(url, header: reopenedHeader, start: 0, end: Double(frames) / rate, pixelsPerSecond: rate / 2048)
        return value.complete ? value : nil
    }
    precondition(restored.blocks.map(\.channels) == completeByStep[1024]!.blocks.map(\.channels))
    let reopenedData = try Data(contentsOf: cacheURL)
    precondition(reopenedData == persisted, "a valid indexed cache must reopen without rewriting it")
    print("GPU_VERTEX_PERSISTENT_MULTILEVEL_REOPEN_AND_SEAMS_OK")
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    reopened.evictSourcePyramidsForTest()
    let warmVersion = reopened.version(url)
    for _ in 0..<100 {
        let warm = reopened.vertexDrawing(url, header: reopenedHeader, start: 0, end: Double(frames) / rate, pixelsPerSecond: rate / 2048)
        precondition(warm.complete && zip(warm.blocks, restored.blocks).allSatisfy { $0 === $1 })
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    precondition(reopened.version(url) == warmVersion, "warm GPU vertices must not reload an evicted source or publish redraws")
    let prewarmed = reopened.cachedCoarserVertices(reopenedHeader, url: url, start: 0, end: Double(frames) / rate, requestedStep: 16_384)
    precondition(!prewarmed.isEmpty && prewarmed.allSatisfy { $0.step >= 16_384 }, "zoom-out overview is prepared before the gesture")
    print("GPU_WARM_VERTICES_NO_SOURCE_RELOAD_AND_PREPARED_ZOOM_OUT_OK")


    // Existing v2/v3 float caches migrate from signed peaks, without audio reads.
    var legacyPeaks = Data()
    func append<T>(_ value: T) { var value = value; withUnsafeBytes(of: &value) { legacyPeaks.append(contentsOf: $0) } }
    for start in stride(from: 0, to: frames, by: 256) {
        let end = min(frames, start + 256)
        for channel in 0..<3 {
            func sample(_ index: Int) -> Float { channel < 2 ? original[channel][index] : (original[0][index] + original[1][index]) * 0.5 }
            var low = start, high = start
            for index in start..<end {
                if sample(index) < sample(low) { low = index }
                if sample(index) > sample(high) { high = index }
            }
            for value in [sample(start), sample(end - 1), sample(low), sample(high)] { append(value.bitPattern.littleEndian) }
            append(UInt16(low - start).littleEndian); append(UInt16(high - start).littleEndian)
        }
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let oldDisk: [String: Any] = ["version": 2, "size": attributes[.size]!,
        "modified": (attributes[.modificationDate] as! Date).timeIntervalSinceReferenceDate,
        "rate": rate, "frames": frames, "channels": 3, "samples": legacyPeaks]
    try PropertyListSerialization.data(fromPropertyList: oldDisk, format: .binary, options: 0).write(to: cacheURL)
    let migratedCache = TimelineAudioWaveform()
    let migratedHeader = awaitValue { migratedCache.header(url) }
    let migrated: TimelineAudioWaveform.VertexDrawing = awaitValue {
        let value = migratedCache.vertexDrawing(url, header: migratedHeader, start: 0, end: Double(frames) / rate, pixelsPerSecond: rate / 2048)
        return value.complete ? value : nil
    }
    precondition(migrated.blocks.map(\.channels) == restored.blocks.map(\.channels))
    let migratedDisk = try Data(contentsOf: cacheURL)
    precondition(migratedDisk == persisted, "legacy signed extrema convert to exactly the same compact envelope as original audio")
    print("GPU_VERTEX_V2_CACHE_MIGRATES_WITHOUT_CHANGING_SOURCE_CURVE_OK")
    for version in [2, 3] {
        let unavailableAudio = directory.appendingPathComponent("legacy-\(version)-\(Int(rate)).mp3")
        try Data("intentionally unavailable audio decoder".utf8).write(to: unavailableAudio)
        let attributes = try FileManager.default.attributesOfItem(atPath: unavailableAudio.path)
        var saved = oldDisk
        saved["version"] = version; saved["size"] = attributes[.size]!
        saved["modified"] = (attributes[.modificationDate] as! Date).timeIntervalSinceReferenceDate
        let destination = TimelineAudioWaveform.diskCacheURL(unavailableAudio)
        try PropertyListSerialization.data(fromPropertyList: saved, format: .binary, options: 0).write(to: destination)
        let restored = try WaveformSource.loadOrBuild(unavailableAudio,
            header: TimelineAudioWaveform.Header(rate: rate, frames: Int64(frames), channels: 2))
        precondition(restored.ownedByteCount == 0 && restored.mappedByteCount > 0)
        precondition(restored.vertices(start: 0, step: 1024, span: Int(TimelineAudioWaveform.span(step: 1024)), key: "migration").channels == migrated.blocks.first!.channels,
            "v2/v3 migration must use the existing signed peak cache even when audio cannot be decoded")
    }
    print("GPU_LEGACY_MIGRATION_WITHOUT_DECODABLE_AUDIO_AND_ZERO_OWNED_PEAK_BYTES_OK")

    // Same-length edits used to collide with the old path + frame-count key.
    _ = try createAudio(url, rate: rate, frames: frames, amplitude: 0.75)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: url.path)
    RunLoop.main.run(until: Date().addingTimeInterval(1.05))
    let changedHeader: TimelineAudioWaveform.Header = awaitValue {
        guard let value = cache.header(url, refresh: true), value.cachePrefix != header.cachePrefix else { return nil }
        return value
    }
    let changed: TimelineAudioWaveform.VertexDrawing = awaitValue {
        let value = cache.vertexDrawing(url, header: changedHeader, start: 0, end: Double(frames) / rate, pixelsPerSecond: rate / 2048)
        return value.complete ? value : nil
    }
    precondition(changed.blocks.first!.key != restored.blocks.first!.key)
    let maximum = changed.blocks.flatMap { $0.channels[0] }.map { abs($0.y) }.max()!
    precondition(maximum > 0.74, "source replacement must invalidate memory and disk blocks despite identical length")
    print("GPU_VERTEX_SAME_LENGTH_SOURCE_REPLACEMENT_INVALIDATES_MEMORY_AND_DISK_OK")
}

extension TimelineAudioWaveform {
    func evictTransientDrawingCachesForTest() {
        vertexBlocks.removeAllObjects(); headers.removeAllObjects()
        sources.removeAllObjects(); vertexOverviews.removeAllObjects()
    }
    func pendingCountForTest() -> Int { lock.lock(); defer { lock.unlock() }; return pending.count }
    func projectPinnedCountForTest() -> Int {
        projectCacheLock.lock(); defer { projectCacheLock.unlock() }; return projectOverviews.count
    }
    func projectPeakBytesForTest() -> (owned: Int, mapped: Int, overviews: Int) {
        projectCacheLock.lock(); defer { projectCacheLock.unlock() }
        return (projectSources.values.reduce(0) { $0 + $1.ownedByteCount },
                projectSources.values.reduce(0) { $0 + $1.mappedByteCount },
                projectOverviews.values.reduce(0) { $0 + $1.cost })
    }
}
// Cold preparation must finish every unique file before exposing the project.
// A missing file cannot stop the batch, and reopening must not rewrite caches.
let coldDirectory = directory.appendingPathComponent("Concurrent/Stems")
try FileManager.default.createDirectory(at: coldDirectory, withIntermediateDirectories: true)
let coldURLs = try (0..<8).map { index -> URL in
    let target = coldDirectory.appendingPathComponent("source-\(index).wav")
    try FileManager.default.copyItem(at: directory.appendingPathComponent("source-44100.wav"), to: target)
    return target
}
let missingURL = coldDirectory.appendingPathComponent("missing.wav")
var coldDone = false
var coldProgress: [Int] = []
let coldCache = TimelineAudioWaveform()
Task { @MainActor in
    await coldCache.preload(coldURLs + coldURLs + [missingURL]) { done, total in
        precondition(total == 9)
        coldProgress.append(done)
    }
    coldDone = true
}
let _: Bool = awaitValue { coldDone ? true : nil }
precondition(coldProgress == Array(1...9), "progress is ordered, deduplicated and includes failed inputs")
precondition(coldCache.projectPinnedCountForTest() == 8)
let cacheDates = try coldURLs.map { try FileManager.default.attributesOfItem(atPath: TimelineAudioWaveform.diskCacheURL($0).path)[.modificationDate] as! Date }
let cacheBytes = try coldURLs.map { try Data(contentsOf: TimelineAudioWaveform.diskCacheURL($0)) }
precondition(cacheBytes.allSatisfy { $0 == cacheBytes[0] }, "concurrent decoding produces identical peaks for identical audio")
coldDone = false
let reopenedCache = TimelineAudioWaveform()
Task { @MainActor in await reopenedCache.preload(coldURLs); coldDone = true }
let _: Bool = awaitValue { coldDone ? true : nil }
let reopenedDates = try coldURLs.map { try FileManager.default.attributesOfItem(atPath: TimelineAudioWaveform.diskCacheURL($0).path)[.modificationDate] as! Date }
precondition(cacheDates == reopenedDates && reopenedCache.projectPinnedCountForTest() == 8,
             "a fresh project cache reuses every persistent waveform without rebuilding")
print("GPU_CONCURRENT_COLD_PRELOAD_DEDUP_FAILURE_PROGRESS_AND_WARM_DISK_REUSE_OK")

let preloadedDecode = DispatchQueue(label: "jaras.preload.test.decode")
let preloadedCache = TimelineAudioWaveform(worker: preloadedDecode)
let preloadedURLs = [44100, 48000].map { directory.appendingPathComponent("source-\($0).wav") }
var preloadFinished = false
Task { @MainActor in await preloadedCache.preload(preloadedURLs); preloadFinished = true }
let _: Bool = awaitValue { preloadFinished ? true : nil }
let footprint = preloadedCache.projectPeakBytesForTest()
precondition(footprint.owned == 0 && footprint.mapped > 0,
             "project preloading pins mapped cache indices, never decoded copies of every source")
print("GPU_PROJECT_COMPACT_CACHE_BYTES owned=\(footprint.owned) mapped=\(footprint.mapped) overview=\(footprint.overviews)")
preloadedCache.evictTransientDrawingCachesForTest()
preloadedDecode.suspend()
var unavailablePaths: [(URL, URL)] = []
for url in preloadedURLs {
    for original in [url, TimelineAudioWaveform.diskCacheURL(url)] {
        let moved = original.appendingPathExtension("offline")
        try FileManager.default.moveItem(at: original, to: moved)
        unavailablePaths.append((original, moved))
    }
}
for url in preloadedURLs {
    let header = preloadedCache.header(url)!
    let duration = Double(header.frames) / header.rate
    for scale in [0.1, 1, 20, 300, 2000, 12000, 81920] {
        for start in [0.0, duration * 0.3, duration * 0.8] {
            let result = preloadedCache.vertexDrawing(url, header: header, start: start, end: duration, pixelsPerSecond: scale)
            precondition(result.complete && !result.blocks.isEmpty,
                         "every zoom returns a complete RAM curve after transient caches are evicted")
            precondition(result.blocks.first!.start <= Int64(start * header.rate) && result.blocks.last!.end >= header.frames)
        }
    }
}
preloadedDecode.resume()
for (original, moved) in unavailablePaths { try FileManager.default.moveItem(at: moved, to: original) }
precondition(preloadedCache.pendingCountForTest() == 0, "zoom queues no decode or geometry construction for a preloaded project")
precondition(preloadedCache.projectPinnedCountForTest() == 2)
preloadFinished = false
Task { @MainActor in await preloadedCache.preload([]); preloadFinished = true }
let _: Bool = awaitValue { preloadFinished ? true : nil }
precondition(preloadedCache.projectPinnedCountForTest() == 0, "changing projects releases the preceding project's strong RAM curves")
print("GPU_PROJECT_PRELOAD_ALL_ZOOMS_IMMEDIATE_COMPLETE_RAM_NO_BACKGROUND_WORK_AND_RELEASE_OK")

let cancelledCache = TimelineAudioWaveform()
var cancelledPreloadDone = false, cancelledProgress = false
Task { @MainActor in
    await cancelledCache.preload(coldURLs, cancelled: { true }) { _, _ in cancelledProgress = true }
    cancelledPreloadDone = true
}
let _: Bool = awaitValue { cancelledPreloadDone ? true : nil }
precondition(!cancelledProgress && cancelledCache.projectPinnedCountForTest() == 0, "cancelled preparation must not install caches or report stale progress")
print("CANCELLED_PROJECT_PRELOAD_DOES_NOT_INSTALL_OR_REPORT_PROGRESS_OK")
