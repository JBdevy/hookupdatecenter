import Foundation
import AVFoundation

setbuf(stdout, nil)
private let pcmReadLock = NSLock()
private var pcmPageReads: [(path: String, start: Int64, frames: Int)] = []
private var pcmPageFailure: (path: String, start: Int64)?
func shouldFailPCMPageForTest(_ url: URL, start: Int64) -> Bool {
    pcmReadLock.lock(); defer { pcmReadLock.unlock() }
    return pcmPageFailure?.path == url.path && pcmPageFailure?.start == start
}
func failPCMPageForTest(_ url: URL?, start: Int64 = 0) {
    pcmReadLock.lock(); defer { pcmReadLock.unlock() }
    pcmPageFailure = url.map { ($0.path, start) }
}
func recordPCMPageReadForTest(_ url: URL, start: Int64, frames: Int) {
    pcmReadLock.lock(); defer { pcmReadLock.unlock() }
    pcmPageReads.append((url.path, start, frames))
}
func pcmPageReadsForTest(_ url: URL) -> [(start: Int64, frames: Int)] {
    pcmReadLock.lock(); defer { pcmReadLock.unlock() }
    return pcmPageReads.filter { $0.path == url.path }.map { ($0.start, $0.frames) }
}
for value: Float in [-128, -8, -2, -1, -0.95, -0.0001, 0, 0.0001, 0.7, 1, 2, 8, 128] {
    let restored = WaveformPeakCodec.decode(WaveformPeakCodec.encode(value))
    let bound: Float = abs(value) <= 1 ? 1 / 49152 : abs(value) * 0.00035
    precondition(abs(restored - value) <= bound, "RPKL preserves polarity, quiet detail and floating-point headroom")
}
print("RPKL_SIGNED_16BIT_QUANTIZATION_AND_FLOAT_HEADROOM_OK")
func extremaFixture(_ samples: [Float], step: Int) -> [SIMD2<Float>] {
    TimelineAudioWaveform.VertexBlock(pcm: TimelineAudioWaveform.PCM(channels: [samples]),
        start: 0, span: samples.count, step: step, rate: 48_000, key: "extrema-fixture").channels[0]
}
let tiedExtrema = extremaFixture([0, 1, 1, -1, -1, 0, 1, 1, -1, -1, 0], step: 6)
precondition(tiedExtrema.map(\.x) == [0, 1, 3, 5, 6, 8, 10],
             "equal extrema keep their first actual sample position in each bucket")
let firstNaN = Float(bitPattern: 0x7fc00001)
let startsNaN = extremaFixture([firstNaN, 1, -2, 0], step: 4)
precondition(startsNaN.map(\.x) == [0, 3] && startsNaN[0].y.bitPattern == (firstNaN.bitPattern ^ 0x80000000),
             "an initial NaN must preserve the existing first-sample comparison behavior and payload")
let middleNaN = extremaFixture([0, 1, .nan, -1, 0], step: 4)
precondition(middleNaN.map(\.x) == [0, 1, 3, 4], "a later NaN must not replace a finite bucket extremum")
precondition(extremaFixture([0, .infinity, .infinity, -.infinity, -.infinity, 0], step: 6).map(\.x) == [0, 1, 3, 5])
let signedZero = extremaFixture([-0.0, 0, 0, -0.0, 1], step: 4)
precondition(signedZero.map(\.x) == [0, 3, 4] && signedZero[0].y.bitPattern == 0 && signedZero[1].y.bitPattern == 0)
print("GPU_PCM_EXTREMA_FIRST_EQUAL_TIES_NAN_PAYLOAD_INFINITY_AND_SIGNED_ZERO_OK")
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
    let detailCache = TimelineAudioWaveform()
    var prepared = false
    Task { @MainActor in await detailCache.preload([copy]); prepared = true }
    _ = awaitValue { prepared ? true : nil }
    let detailHeader = detailCache.header(copy)!
    let tail: TimelineAudioWaveform.VertexDrawing = awaitValue {
        let drawing = detailCache.vertexDrawing(copy, header: detailHeader,
            start: Double(max(0, detailHeader.frames - 2048)) / detailHeader.rate,
            end: Double(detailHeader.frames) / detailHeader.rate, pixelsPerSecond: detailHeader.rate)
        return drawing.complete ? drawing : nil
    }
    precondition(tail.blocks.last?.end == detailHeader.frames && tail.blocks.allSatisfy { !$0.isPeakEnvelope && $0.step == 1 },
                 "close sample detail must cover compressed source EOF including known MP3 packet padding")
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
    func boundedPCMForTest(_ url: URL, header: Header, start: Int64, span: Int) -> PCM? {
        let old = readPCM(url, header: header, start: start, span: span, key: "bounded-read:\(url.path):\(start):\(span)")
        let view = readPCMView(url, header: header, start: start, span: span)
        precondition((old == nil) == (view == nil), "page views preserve failed-read/short-EOF contract")
        if let old, let view {
            for channel in old.channels.indices {
                let values = view.slices.flatMap { Array($0.page.channels[channel][$0.range]) }
                precondition(old.channels[channel].elementsEqual(values), "page views preserve every decoded sample and their order")
            }
        }
        return old
    }
    func pcmCacheLimitForTest() -> Int { pcm.totalCostLimit }
}
for rate in [44_100.0, 48_000.0] {
    let url = directory.appendingPathComponent("source-\(Int(rate)).wav")
    let frames = 131_373 // Deliberately cross decoder and pyramid boundaries.
    let original = try createAudio(url, rate: rate, frames: frames)
    let decode = DispatchQueue(label: "jaras.vertices.test.decode")
    let cache = TimelineAudioWaveform(worker: decode)
    let header = awaitValue { cache.header(url) }
    for span in [512, 768, 1024, 10_240, 24_576] {
        for start in [Int64(0), Int64(frames - 17)] {
            let pcm = decode.sync { cache.boundedPCMForTest(url, header: header, start: start, span: span)! }
            let count = min(span + 1, frames - Int(start))
            precondition(pcm.channels.allSatisfy { $0.count == count },
                         "PCM reads must contain only the interval plus one boundary sample, clamped at EOF")
            for channel in pcm.channels.indices {
                precondition(pcm.channels[channel].elementsEqual(original[channel][Int(start)..<(Int(start) + count)]),
                             "bounded PCM reads must preserve every original signed sample")
            }
        }
    }
    print("GPU_PCM_READS_ONLY_SPAN_PLUS_ONE_WITH_EXACT_SAMPLES_AND_SHORT_EOF_OK rate=\(rate)")
    decode.suspend()
    let began = ProcessInfo.processInfo.systemUptime
    let unavailable = cache.vertexDrawing(url, header: header, start: 0, end: 512 / rate, pixelsPerSecond: rate)
    let lookupTime = ProcessInfo.processInfo.systemUptime - began
    decode.resume()
    precondition(!unavailable.complete && unavailable.blocks.isEmpty && lookupTime < 0.05,
                 "a cold GPU lookup must never wait for decode or build paths")

    var completeByStep: [Int: TimelineAudioWaveform.VertexDrawing] = [:]
    for step in TimelineAudioWaveform.detailSteps + [256, 512, 1024, 16_384, 65_536] {
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
        if step < TimelineAudioWaveform.peakFramesPerInterval {
            for (left, right) in zip(drawing.blocks, drawing.blocks.dropFirst()) {
                precondition(left.end == right.start, "nonnested PCM steps must still have contiguous block coverage")
                for channel in left.channels.indices {
                    precondition(Int64(left.channels[channel].last!.x) + left.start == right.start &&
                                 left.channels[channel].last!.y == right.channels[channel].first!.y,
                                 "all 16 PCM levels share the exact boundary sample, including spans not divisible by the step")
                }
            }
        }
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
    for scale in [0.1, 1, 20, 300, 2000, 12000, 81920]
        where TimelineAudioWaveform.step(rate: header.rate, pixelsPerSecond: scale) >= TimelineAudioWaveform.peakFramesPerInterval {
        for start in [0.0, duration * 0.3, duration * 0.8] {
            let result = preloadedCache.vertexDrawing(url, header: header, start: start, end: duration, pixelsPerSecond: scale)
            precondition(result.complete && !result.blocks.isEmpty,
                         "every peak zoom returns a complete RAM curve after transient caches are evicted")
            precondition(result.blocks.first!.start <= Int64(start * header.rate) && result.blocks.last!.end >= header.frames)
        }
    }
}
preloadedDecode.resume()
for (original, moved) in unavailablePaths { try FileManager.default.moveItem(at: moved, to: original) }
precondition(preloadedCache.pendingCountForTest() == 0, "peak zoom queues no decode or geometry construction for a preloaded project")
precondition(preloadedCache.projectPinnedCountForTest() == 2)
print("GPU_PROJECT_PRELOAD_PEAK_ZOOMS_IMMEDIATE_COMPLETE_RAM_NO_BACKGROUND_WORK_OK")

for url in preloadedURLs {
    let header = preloadedCache.header(url)!
    let start = 12000.25 / header.rate, end = 13024.5 / header.rate
    preloadedDecode.suspend()
    let began = ProcessInfo.processInfo.systemUptime
    let coldDetail = preloadedCache.vertexDrawing(url, header: header, start: start, end: end, pixelsPerSecond: header.rate)
    let coldLookupTime = ProcessInfo.processInfo.systemUptime - began
    let coarse = preloadedCache.cachedCoarserVertices(header, url: url, start: start, end: end, requestedStep: 1)
    preloadedDecode.resume()
    precondition(!coldDetail.complete && coldDetail.blocks.isEmpty && coldLookupTime < 0.05,
                 "cold sample detail must queue without reading PCM on the drawing thread")
    precondition(!coarse.isEmpty && coarse.allSatisfy(\.isPeakEnvelope) &&
                 Double(coarse.first!.start) <= start * header.rate && Double(coarse.last!.end) >= end * header.rate,
                 "the complete prepared envelope remains available while sample detail is pending")
    let detail: TimelineAudioWaveform.VertexDrawing = awaitValue {
        let drawing = preloadedCache.vertexDrawing(url, header: header, start: start, end: end, pixelsPerSecond: header.rate)
        return drawing.complete ? drawing : nil
    }
    precondition(detail.requestedStep == 1 && detail.blocks.allSatisfy { !$0.isPeakEnvelope && $0.step == 1 },
                 "close zoom must resolve original samples even after project peak preparation")
    for block in detail.blocks {
        for channel in 0..<3 { for point in block.channels[channel] {
            let frame = Int(block.start) + Int(point.x)
            let left = Float(sin(Double(frame) * 2 * .pi * 439 / header.rate)) * 0.75
            let right: Float = frame == 12_345 ? -0.95 : 0
            let expected = channel == 0 ? left : channel == 1 ? right : (left + right) * 0.5
            precondition(abs(point.y + expected) < 0.000001,
                         "preloaded close zoom preserves signed PCM, stereo phase and original sample positions")
        } }
    }
    preloadedDecode.suspend()
    let warmBegan = ProcessInfo.processInfo.systemUptime
    for _ in 0..<500 {
        let warm = preloadedCache.vertexDrawing(url, header: header, start: start, end: end, pixelsPerSecond: header.rate)
        precondition(warm.complete && zip(warm.blocks, detail.blocks).allSatisfy { $0 === $1 })
    }
    let warmTime = ProcessInfo.processInfo.systemUptime - warmBegan
    let pending = preloadedCache.pendingCountForTest()
    preloadedDecode.resume()
    precondition(pending == 0, "warm sample zoom must not schedule another decode")
    print("GPU_PRELOADED_REAL_SAMPLE_DETAIL_ASYNC_FALLBACK_AND_WARM_REUSE_OK rate=\(header.rate) queries=500 seconds=\(warmTime)")
}
preloadFinished = false
Task { @MainActor in await preloadedCache.preload([]); preloadFinished = true }
let _: Bool = awaitValue { preloadFinished ? true : nil }
precondition(preloadedCache.projectPinnedCountForTest() == 0, "changing projects releases the preceding project's strong RAM curves")
print("GPU_PROJECT_PRELOAD_RELEASES_SOURCE_PEAKS_AFTER_DETAIL_LOOKUPS_OK")

let cancelledCache = TimelineAudioWaveform()
var cancelledPreloadDone = false, cancelledProgress = false
Task { @MainActor in
    await cancelledCache.preload(coldURLs, cancelled: { true }) { _, _ in cancelledProgress = true }
    cancelledPreloadDone = true
}
let _: Bool = awaitValue { cancelledPreloadDone ? true : nil }
precondition(!cancelledProgress && cancelledCache.projectPinnedCountForTest() == 0, "cancelled preparation must not install caches or report stale progress")
print("CANCELLED_PROJECT_PRELOAD_DOES_NOT_INSTALL_OR_REPORT_PROGRESS_OK")

let boundedQueue = DispatchQueue(label: "jaras.vertices.bounded-prefetch")
let boundedCache = TimelineAudioWaveform(worker: boundedQueue)
let boundedURL = preloadedURLs[0]
let boundedHeader = awaitValue { boundedCache.header(boundedURL) }
boundedQueue.sync {}
boundedQueue.suspend()
_ = boundedCache.vertexDrawing(boundedURL, header: boundedHeader, start: 0,
    end: Double(boundedHeader.frames) / boundedHeader.rate, pixelsPerSecond: boundedHeader.rate, prefetch: true)
precondition(boundedCache.pendingCountForTest() == 8, "speculative PCM must leave queue capacity for visible work")
_ = boundedCache.vertexDrawing(boundedURL, header: boundedHeader, start: 0,
    end: Double(boundedHeader.frames) / boundedHeader.rate, pixelsPerSecond: boundedHeader.rate)
precondition(boundedCache.pendingCountForTest() == 64, "foreground PCM must retain its bounded capacity after speculation")
boundedQueue.resume()
boundedQueue.sync {}
print("GPU_SPECULATIVE_PCM_QUEUE_LEAVES_FOREGROUND_CAPACITY_AND_STAYS_BOUNDED_OK")

for rate in [44_100.0, 48_000.0] {
    let pagedURL = directory.appendingPathComponent("shared-pages-\(Int(rate)).wav")
    let frames = 131_373
    let samples = try createAudio(pagedURL, rate: rate, frames: frames)
    let pageWorker = DispatchQueue(label: "jaras.vertices.shared-pages")
    let pageCache = TimelineAudioWaveform(worker: pageWorker)
    let pageHeader = awaitValue { pageCache.header(pagedURL) }
    let first = 65_001.25, last = 78_003.5
    var expectedPages = Set<Int64>()
    for step in TimelineAudioWaveform.detailSteps {
        let drawing: TimelineAudioWaveform.VertexDrawing = awaitValue {
            let value = pageCache.vertexDrawing(pagedURL, header: pageHeader,
                start: first / rate, end: last / rate, pixelsPerSecond: rate / Double(step * 2))
            return value.complete ? value : nil
        }
        for block in drawing.blocks {
            // Include the shared boundary sample, except at the real file EOF.
            for page in (block.start / 8192)...(min(block.end, Int64(frames - 1)) / 8192) { expectedPages.insert(page * 8192) }
            for point in block.channels[0] {
                precondition(point.y == -samples[0][Int(block.start) + Int(point.x)],
                    "assembling nonnested spans from shared pages preserves every real vertex")
            }
        }
    }
    pageWorker.sync {}
    let reads = pcmPageReadsForTest(pagedURL)
    precondition(reads.count == expectedPages.count && Set(reads.map(\.start)) == expectedPages,
        "all 16 overlapping levels must decode each intersecting aligned PCM page exactly once")
    precondition(reads.allSatisfy { $0.start % 8192 == 0 && $0.frames <= 8192 } && reads.count < (frames + 8191) / 8192,
        "detail reads are bounded pages around the visible source window, never a whole-file decode")
    precondition(pageCache.pcmCacheLimitForTest() == 48 * 1024 * 1024,
        "shared pages must stay inside the existing PCM cache budget")
    // Bypass ready vertices and assemble the same intervals directly. Page reuse
    // must still avoid AVAudioFile reads, independent of geometry cache hits.
    for step in TimelineAudioWaveform.detailSteps.reversed() {
        let span = TimelineAudioWaveform.span(step: step)
        let start = Int64(first) / Int64(span) * Int64(span)
        let pcm = pageWorker.sync { pageCache.boundedPCMForTest(pagedURL, header: pageHeader, start: start, span: span)! }
        precondition(pcm.channels[0].elementsEqual(samples[0][Int(start)..<(Int(start) + span + 1)]))
    }
    precondition(pcmPageReadsForTest(pagedURL).count == reads.count,
        "new span variants must reuse decoded pages without retaining duplicate raw-span cache entries")
    // The final short page is cached too, including requests beginning within it.
    let tailStart = Int64(frames - 17)
    let tail = pageWorker.sync { pageCache.boundedPCMForTest(pagedURL, header: pageHeader, start: tailStart, span: 512)! }
    let afterTail = pcmPageReadsForTest(pagedURL).count
    let tailAgain = pageWorker.sync { pageCache.boundedPCMForTest(pagedURL, header: pageHeader, start: tailStart + 3, span: 768)! }
    precondition(tail.channels[0].elementsEqual(samples[0].suffix(17)) && tailAgain.channels[0].elementsEqual(samples[0].suffix(14)))
    precondition(pcmPageReadsForTest(pagedURL).count == afterTail && pcmPageReadsForTest(pagedURL).last!.frames == frames % 8192,
        "partial final pages are reused without seeking the decoder again")

    // Atomic same-path replacement leaves the old decoder descriptor open.
    // Project preload updates the version without calling header(refresh:true).
    let replacementURL = directory.appendingPathComponent("replacement-\(Int(rate)).wav")
    let replacement = try createAudio(replacementURL, rate: rate, frames: frames, amplitude: 0.75)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: replacementURL.path)
    try FileManager.default.removeItem(at: pagedURL)
    try FileManager.default.moveItem(at: replacementURL, to: pagedURL)
    var reloaded = false
    Task { @MainActor in await pageCache.preload([pagedURL]); reloaded = true }
    _ = awaitValue { reloaded ? true : nil }
    let replacementHeader = pageCache.header(pagedURL)!
    precondition(replacementHeader.cachePrefix != pageHeader.cachePrefix)
    let replaced = pageWorker.sync {
        pageCache.boundedPCMForTest(pagedURL, header: replacementHeader, start: 65_530, span: 1024)!
    }
    precondition(replaced.channels[0].elementsEqual(replacement[0][65_530..<(65_530 + 1025)]),
        "both shared pages and decoder handles must honor the replacement source version")
    precondition(pcmPageReadsForTest(pagedURL).count == afterTail + 2,
        "same-path replacement must decode fresh versioned pages instead of old cached samples")
    print("GPU_SHARED_PCM_PAGES_16_LEVELS_READ_ONCE_BOUNDED_WINDOW_SHORT_EOF_AND_SOURCE_REPLACEMENT_OK rate=\(rate) pages=\(reads.count)")
}

// A stale length can expose a positive short non-MP3 read. Return only the real
// contiguous prefix and cache it, without inventing samples or skipping a gap.
let shortURL = directory.appendingPathComponent("short-decoder-page.wav")
let shortSamples = try createAudio(shortURL, rate: 48_000, frames: 9_000)
let shortQueue = DispatchQueue(label: "jaras.vertices.short-page")
let shortCache = TimelineAudioWaveform(worker: shortQueue)
let staleLength = TimelineAudioWaveform.Header(rate: 48_000, frames: 10_000, channels: 2,
    sourcePath: shortURL.path, sourceVersion: "stale-length")
let shortPCM = shortQueue.sync { shortCache.boundedPCMForTest(shortURL, header: staleLength, start: 8_000, span: 1_500)! }
precondition(shortPCM.channels[0].elementsEqual(shortSamples[0][8_000..<9_000]))
let shortReads = pcmPageReadsForTest(shortURL).count
let shortAgain = shortQueue.sync { shortCache.boundedPCMForTest(shortURL, header: staleLength, start: 8_500, span: 1_500)! }
let beyondShort = shortQueue.sync { shortCache.boundedPCMForTest(shortURL, header: staleLength, start: 9_100, span: 512) }
precondition(shortAgain.channels[0].elementsEqual(shortSamples[0][8_500..<9_000]) && beyondShort == nil)
precondition(pcmPageReadsForTest(shortURL).count == shortReads,
    "valid short pages must be retained, and missing samples cannot be stitched across a gap")
print("GPU_SHARED_PCM_POSITIVE_SHORT_PAGE_PRESERVES_CONTIGUOUS_PREFIX_WITHOUT_REDECODE_OK")

let failingURL = directory.appendingPathComponent("retry-page.wav")
let retrySamples = try createAudio(failingURL, rate: 48_000, frames: 20_000)
let retryQueue = DispatchQueue(label: "jaras.vertices.retry-page")
let retryCache = TimelineAudioWaveform(worker: retryQueue)
let retryHeader = awaitValue { retryCache.header(failingURL) }
failPCMPageForTest(failingURL, start: 8192)
let failedPCM = retryQueue.sync { retryCache.boundedPCMForTest(failingURL, header: retryHeader, start: 8100, span: 512) }
precondition(failedPCM == nil, "a failed later page must not become a permanently cached partial vertex block")
failPCMPageForTest(nil)
let retriedPCM = retryQueue.sync { retryCache.boundedPCMForTest(failingURL, header: retryHeader, start: 8100, span: 512)! }
precondition(retriedPCM.channels[0].elementsEqual(retrySamples[0][8100..<8613]))
precondition(pcmPageReadsForTest(failingURL).count == 2, "retry keeps the preceding successful page and decodes only the missing page")

let exactEOFURL = directory.appendingPathComponent("exact-page-eof.wav")
let exactEOFSamples = try createAudio(exactEOFURL, rate: 48_000, frames: 8192)
let exactEOFHeader = TimelineAudioWaveform.Header(rate: 48_000, frames: 9000, channels: 2,
    sourcePath: exactEOFURL.path, sourceVersion: "stale-boundary-length")
let exactEOFPCM = retryQueue.sync { retryCache.boundedPCMForTest(exactEOFURL, header: exactEOFHeader, start: 8100, span: 512)! }
precondition(exactEOFPCM.channels[0].elementsEqual(exactEOFSamples[0][8100..<8192]),
    "a real EOF exactly on a page boundary preserves its available prefix")
print("GPU_SHARED_PCM_FAILED_PAGE_RETRIES_WITHOUT_PARTIAL_VERTEX_POISONING_AND_EXACT_PAGE_EOF_OK")

// Recreated headers may represent the same file/version, while different files
// can have identical sample counts and names. Reuse the former only.
do {
    let a = directory.appendingPathComponent("gravação-\(String(repeating: "á", count: 40))/Guitarra.wav")
    let b = directory.appendingPathComponent("outra-gravação/Guitarra.wav")
    for url in [a, b] { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
    _ = try createAudio(a, rate: 48_000, frames: 4096, amplitude: 0.2)
    _ = try createAudio(b, rate: 48_000, frames: 4096, amplitude: 0.8)
    let cache = TimelineAudioWaveform()
    func block(_ url: URL, version: String, withPath: Bool = true) -> TimelineAudioWaveform.VertexBlock {
        let header = TimelineAudioWaveform.Header(rate: 48_000, frames: 4096, channels: 2,
            sourcePath: withPath ? url.path : nil, sourceVersion: version)
        return awaitValue {
            let drawing = cache.vertexDrawing(url, header: header, start: 0, end: 0.006, pixelsPerSecond: 24_000)
            return drawing.complete ? drawing.blocks.first : nil
        }
    }
    let original = block(a, version: "first")
    precondition(block(a, version: "first") === original, "equivalent fresh headers share the immutable block")
    precondition(block(a, version: "second") !== original, "source versions must not share cached geometry")
    let other = block(b, version: "first")
    precondition(other !== original && other.channels[0] != original.channels[0], "same basename and duration must not alias other files")
    let fallbackA = block(a, version: "", withPath: false)
    let fallbackB = block(b, version: "", withPath: false)
    precondition(fallbackA !== fallbackB && fallbackA.channels[0] != fallbackB.channels[0])
    precondition(block(a, version: "", withPath: false) === fallbackA)
    print("GPU_VERTEX_CACHE_UNICODE_EQUIVALENT_HEADERS_SOURCE_VERSIONS_AND_FALLBACK_URL_IDENTITY_OK")

    // Project cache lookups must retain String's canonical Unicode equality
    // when a refresh recreates the Header with a different string encoding.
    let project = TimelineAudioWaveform()
    var ready = false
    Task { @MainActor in await project.preload([a]); ready = true }
    let _: Bool = awaitValue { ready ? true : nil }
    let header = project.header(a)!
    let version = String(header.cachePrefix!.dropFirst("\(header.sourcePath!):\(header.frames):\(header.rate):".count))
    let equivalent = TimelineAudioWaveform.Header(rate: header.rate, frames: header.frames, channels: header.channels,
        sourcePath: header.sourcePath!.decomposedStringWithCanonicalMapping, sourceVersion: version)
    let different = TimelineAudioWaveform.Header(rate: header.rate, frames: header.frames, channels: header.channels,
        sourcePath: header.sourcePath, sourceVersion: version + "-replaced")
    project.evictTransientDrawingCachesForTest()
    weak var releasedProjectBlock: TimelineAudioWaveform.VertexBlock?
    do {
        let original = project.vertexDrawing(a, header: header, start: 0, end: Double(header.frames) / header.rate,
            pixelsPerSecond: header.rate / 512, cachedOnly: true)
        let recreated = project.vertexDrawing(a, header: equivalent, start: 0, end: Double(header.frames) / header.rate,
            pixelsPerSecond: header.rate / 512, cachedOnly: true)
        precondition(original.complete && recreated.complete && original.blocks.first === recreated.blocks.first,
                     "equivalent fresh Unicode headers must find the pinned project blocks immediately")
        let replaced = project.vertexDrawing(a, header: different, start: 0, end: Double(header.frames) / header.rate,
            pixelsPerSecond: header.rate / 512, cachedOnly: true)
        precondition(!replaced.complete && replaced.blocks.isEmpty,
                     "a changed file version must not borrow the old project's source or overview")
        releasedProjectBlock = original.blocks.first
    }
    ready = false
    Task { @MainActor in await project.preload([]); ready = true }
    let _: Bool = awaitValue { ready ? true : nil }
    project.evictTransientDrawingCachesForTest()
    precondition(releasedProjectBlock == nil && header.frames == equivalent.frames,
                 "old headers and source identities must not retain an unloaded project's waveform blocks")
    print("GPU_PINNED_PROJECT_UNICODE_EQUAL_HEADERS_VERSION_ISOLATION_AND_RELEASE_OK")
}

extension TimelineAudioWaveform {
    func verifyDecoderRetention(_ urls: [URL]) throws {
        // This isolated cache is accessed synchronously only by this test.
        let limit = Self.decoderLimit
        precondition(urls.count > limit)
        let original = try urls.prefix(limit).map { try file($0, version: "v1") }
        let touched = try file(urls[0], version: "v1")
        precondition(touched === original[0])
        _ = try file(urls[limit], version: "v1")
        precondition(files.count == limit, "opening a new source must keep decoder ownership bounded")
        precondition(files[urls[1].path] == nil, "only the least recently used decoder is evicted")
        let retainedFirst = try file(urls[0], version: "v1")
        let retainedLast = try file(urls[limit - 1], version: "v1")
        let replaced = try file(urls[0], version: "v2")
        precondition(retainedFirst === original[0])
        precondition(retainedLast === original[limit - 1])
        precondition(replaced !== original[0], "a source version change replaces its open handle")
        precondition(files.count == limit)
    }
    static var decoderLimitForTest: Int { decoderLimit }
}
do {
    let original = directory.appendingPathComponent("decoder-pool.wav")
    _ = try createAudio(original, rate: 48_000, frames: 64)
    let urls = try (0...TimelineAudioWaveform.decoderLimitForTest).map { index -> URL in
        let url = directory.appendingPathComponent("decoder-pool-\(index).wav")
        try FileManager.default.copyItem(at: original, to: url)
        return url
    }
    try TimelineAudioWaveform().verifyDecoderRetention(urls)
    print("GPU_DECODER_POOL_BOUNDED_LRU_RETAINS_ACTIVE_FILES_AND_INVALIDATES_SOURCE_VERSION_OK")
}

// Compare the paged implementation against the previous contiguous PCM algorithm.
func referenceVertices(_ pcm: [[Float]], span: Int, step: Int) -> [[SIMD2<Float>]] {
            let sourceChannels = pcm.count > 1
                ? pcm + [zip(pcm[0], pcm[1]).map { ($0 + $1) * 0.5 }]
                : pcm
            let channels = sourceChannels.map { source -> [SIMD2<Float>] in
                let count = min(source.count, span + 1)
                guard count > 0 else { return [] }
                var vertices: [SIMD2<Float>] = []
                vertices.reserveCapacity(step == 1 ? count : (count / step + 1) * 4)
                var previous = -1, uncompressedCount = 0
                func append(_ frame: Int) {
                    guard frame > previous else { return }
                    let point = SIMD2(Float(frame), -source[frame])
                    let last = vertices.count - 1
                    // Compact exact plateaus as points are emitted. The old
                    // path allocated and scanned the entire curve a second time.
                    if last >= 1, vertices[last].y == point.y, vertices[last - 1].y == point.y {
                        vertices[last] = point
                    } else { vertices.append(point) }
                    previous = frame; uncompressedCount += 1
                }
                if step == 1 {
                    for frame in 0..<count { append(frame) }
                } else {
                    for first in stride(from: 0, to: count, by: step) {
                        let last = min(count, first + step) - 1
                        var low = first, high = first
                        var lowValue = source[first], highValue = lowValue
                        for frame in first...last {
                            let value = source[frame]
                            if value < lowValue { low = frame; lowValue = value }
                            if value > highValue { high = frame; highValue = value }
                        }
                        append(first)
                        if low < high { append(low); append(high) } else { append(high); append(low) }
                        append(last)
                    }
                }
                return vertices.count < uncompressedCount / 2 ? vertices.withUnsafeBufferPointer { Array($0) } : vertices
            }
            return channels
}

import Foundation

func exactBits(_ lhs: [[SIMD2<Float>]], _ rhs: [[SIMD2<Float>]]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    for channel in lhs.indices {
        guard lhs[channel].count == rhs[channel].count else { return false }
        for index in lhs[channel].indices {
            let a = lhs[channel][index], b = rhs[channel][index]
            guard a.x.bitPattern == b.x.bitPattern && a.y.bitPattern == b.y.bitPattern else { return false }
        }
    }
    return true
}
func makePages(_ channels: [[Float]], pageFrames: Int) -> [TimelineAudioWaveform.PCM] {
    let count = channels.first?.count ?? 0
    return stride(from: 0, to: count, by: pageFrames).map { first in
        TimelineAudioWaveform.PCM(channels: channels.map { Array($0[first..<min(count, first + pageFrames)]) })
    }
}
func makeView(_ pages: [TimelineAudioWaveform.PCM], pageFrames: Int, range: Range<Int>) -> TimelineAudioWaveform.PCMView {
    var slices: [TimelineAudioWaveform.PCMView.Slice] = []
    var frame = range.lowerBound
    while frame < range.upperBound {
        let page = pages[frame / pageFrames]
        let offset = frame % pageFrames
        let count = min(range.upperBound - frame, pageFrames - offset)
        slices.append(.init(page: page, range: offset..<(offset + count)))
        frame += count
    }
    return .init(slices: slices)
}

let detailStepsExact = [1,2,3,4,6,8,12,16,24,32,48,64,80,96,128,192,256,512]
let sampleCount = 65_581
var exactCases = 0
for channelCount in [1,2,4] {
    var state: UInt64 = 0x123456789abcdef
    var channels = (0..<channelCount).map { channel in
        (0..<sampleCount).map { index -> Float in
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Float(Int32(truncatingIfNeeded: state)) / Float(Int32.max) * Float(channel + 1)
        }
    }
    for channel in channels.indices {
        for first in [0,510,8180,16370,24570,32760,65_520] {
            let samples: [Float] = [-0.0,0,0,-0.0,1,1,-1,-1,Float(bitPattern:0x7fc00011),2,-2,.infinity,-.infinity,0]
            channels[channel].replaceSubrange(first..<(first + samples.count), with: samples)
        }
        for first in [1000,9000,20000,42000] {
            channels[channel].replaceSubrange(first..<(first + 512), with: repeatElement(Float(channel % 2), count:512))
        }
    }
    for pageFrames in [8192,113] {
        let pages = makePages(channels, pageFrames: pageFrames)
        let cachedBytes = pages.reduce(0) { $0 + $1.cost }
        let summaryBytes = pages.reduce(0) { sum, page in
            sum + page.waveformChannels.reduce(0) { $0 + ($1.count / 8) * MemoryLayout<SIMD2<UInt8>>.stride }
        }
        precondition(cachedBytes == sampleCount * (channelCount > 1 ? channelCount + 1 : 1) * 4 + summaryBytes,
            "every mono byte and potential lazy extrema byte must fit the existing PCM cache budget")
        for step in detailStepsExact {
            let span = max(512,step * 128)
            for first in [0,1,112,511,8190,8191,8192,8193,12287,16380,32767,64570,65570] {
                let last = min(sampleCount, first + span + 1)
                let view = makeView(pages, pageFrames: pageFrames, range: first..<last)
                let reference = referenceVertices(channels.map { Array($0[first..<last]) }, span:span, step:step)
                let candidate = TimelineAudioWaveform.VertexBlock(pages:view, start:Int64(first),span:span,step:step,rate:48000,key:"exact")
                precondition(exactBits(reference,candidate.channels),
                    "bit-exact channel \(channelCount), page \(pageFrames), step \(step), start \(first)")
                precondition(candidate.start == first && candidate.end == first + min(span, last - first))
                for slice in view.slices {
                    precondition(slice.page === pages[(first + view.slices.prefix(while: { $0.page !== slice.page }).reduce(0) { $0 + $1.range.count }) / pageFrames],
                        "views retain shared decoder pages, never PCM subrange copies")
                }
                exactCases += 1
            }
        }
        for _ in 0..<100 {
            let view = makeView(pages, pageFrames:pageFrames, range:8000..<44000)
            precondition(view.slices.count < 400)
            precondition(pages.reduce(0) { $0 + $1.cost } == cachedBytes)
        }
    }
}
print("PCM_PAGE_VIEWS_BIT_EXACT_ALL_18_LEVELS_\(exactCases)_CASES_MONO_STEREO_MULTICHANNEL_EOF_NAN_ZERO_INFINITY_PLATEAUS_AND_BOUNDED_SHARED_BYTES_OK")

var retainedVertex: TimelineAudioWaveform.VertexBlock?
weak var releasedPage: TimelineAudioWaveform.PCM?
autoreleasepool {
    let page = TimelineAudioWaveform.PCM(channels: [[0,1,-1,0],[1,0,-1,0]])
    releasedPage = page
    for channel in page.channels.indices {
        let original = page.channels[channel].withUnsafeBufferPointer { $0.baseAddress }
        let displayed = page.waveformChannels[channel].withUnsafeBufferPointer { $0.baseAddress }
        precondition(original == displayed, "display channels share PCM storage by value, without doubling cached input bytes")
    }
    let monoAddress = page.waveformChannels[2].withUnsafeBufferPointer { $0.baseAddress }
    for step in detailStepsExact {
        let view = TimelineAudioWaveform.PCMView(slices:[.init(page:page,range:0..<4)])
        retainedVertex = TimelineAudioWaveform.VertexBlock(pages:view,start:0,span:4,step:step,rate:48000,key:"release")
        precondition(page.waveformChannels[2].withUnsafeBufferPointer { $0.baseAddress } == monoAddress,
            "changing LOD never rebuilds the cached mono samples")
    }
}
precondition(releasedPage == nil && retainedVertex != nil,
    "retained vertices must not pin PCM pages outside their byte-bounded cache")
print("PCM_RAW_STORAGE_SHARED_MONO_COMPUTED_ONCE_AND_VERTEX_DOES_NOT_PIN_PAGE_OK")

extension TimelineAudioWaveform {
    func enqueueVertexForPendingTest(_ prefix: String, start: Int64 = 0, span: Int = 512, step: Int = 1,
                                     url: URL, maximumPending: Int = 64, changed: Bool = true,
                                     didRun: @escaping () -> Void) {
        let key = VertexKey(source: VertexSource(prefix), start: start, span: span, step: step)
        enqueue(.vertex(key), url: url, maximumPending: maximumPending) {
            didRun()
            return changed
        }
    }
    func enqueueNamedForPendingTest(_ name: String, url: URL, queue: DispatchQueue? = nil,
                                    maximumPending: Int = 64, changed: Bool = true,
                                    didRun: @escaping () -> Void) {
        enqueue(name, url: url, queue: queue, maximumPending: maximumPending) {
            didRun()
            return changed
        }
    }
}

do {
    let queue = DispatchQueue(label: "test.typed-pending.identity")
    queue.suspend()
    let cache = TimelineAudioWaveform(worker: queue)
    let url = URL(fileURLWithPath: "/tmp/typed-pending-gravação.wav")
    let prefix = "/tmp/gravação/áudio.wav:48000:48000.0:v1"
    var ran: [String] = []
    for index in 0..<128 {
        // Separate header/source objects and equivalent Unicode spelling must
        // still identify the same source version and block.
        let spelling = index.isMultiple(of: 2) ? prefix : prefix.decomposedStringWithCanonicalMapping
        cache.enqueueVertexForPendingTest(spelling, url: url) { ran.append("vertex") }
    }
    cache.enqueueVertexForPendingTest(prefix + ":replacement", url: url) { ran.append("version") }
    cache.enqueueVertexForPendingTest(prefix, start: 512, url: url) { ran.append("start") }
    cache.enqueueVertexForPendingTest(prefix, span: 768, url: url) { ran.append("span") }
    cache.enqueueVertexForPendingTest(prefix, step: 2, url: url) { ran.append("step") }
    for kind in ["header", "geometry", "display", "source"] {
        for _ in 0..<3 {
            cache.enqueueNamedForPendingTest("\(kind):\(prefix)", url: url) { ran.append(kind) }
        }
    }
    precondition(cache.pendingCountForTest() == 9, "typed vertices and existing named jobs deduplicate independently")
    queue.resume()
    queue.sync {}
    precondition(Set(ran) == Set(["vertex", "version", "start", "span", "step", "header", "geometry", "display", "source"]))
    precondition(ran.count == 9 && cache.pendingCountForTest() == 0 && cache.version(url) == 9)

    cache.enqueueVertexForPendingTest(prefix, url: url, changed: false) { ran.append("failed") }
    queue.sync {}
    precondition(cache.pendingCountForTest() == 0 && cache.version(url) == 9,
                 "failed/cancelled work releases its typed key without publishing a source version")
    cache.enqueueVertexForPendingTest(prefix, url: url) { ran.append("retried") }
    queue.sync {}
    precondition(ran.suffix(2) == ["failed", "retried"] && cache.version(url) == 10,
                 "a completed or failed typed request must remain retryable")
}
print("TYPED_PENDING_UNICODE_EQUIVALENCE_SOURCE_VERSION_COORDINATES_NAMED_JOBS_RETRY_AND_COMPLETION_OK")

do {
    let queue = DispatchQueue(label: "test.typed-pending.limits")
    queue.suspend()
    let cache = TimelineAudioWaveform(worker: queue)
    let url = URL(fileURLWithPath: "/tmp/typed-pending-limits.wav")
    var ran = 0
    for index in 0..<7 {
        cache.enqueueNamedForPendingTest("header:\(index)", url: url) { ran += 1 }
    }
    for index in 0..<20 {
        cache.enqueueVertexForPendingTest("limit", start: Int64(index * 512), url: url, maximumPending: 8) { ran += 1 }
    }
    precondition(cache.pendingCountForTest() == 8, "prefetch counts named jobs toward the same limit of eight")
    for index in 0..<100 {
        cache.enqueueVertexForPendingTest("limit", start: Int64(index * 512), url: url) { ran += 1 }
    }
    precondition(cache.pendingCountForTest() == 64, "visible typed work shares the existing global limit of 64")
    cache.enqueueNamedForPendingTest("source:must-wait", url: url) { ran += 1000 }
    precondition(cache.pendingCountForTest() == 64, "named jobs cannot bypass capacity occupied by typed vertices")
    queue.resume()
    queue.sync {}
    precondition(ran == 64 && cache.pendingCountForTest() == 0 && cache.version(url) == 64)
    cache.enqueueNamedForPendingTest("source:must-wait", url: url) { ran += 1 }
    queue.sync {}
    precondition(ran == 65, "capacity rejection leaves named work retryable")
}
print("TYPED_PENDING_MIXED_GLOBAL_CAPACITY_PREFETCH_8_FOREGROUND_64_AND_REJECTED_RETRY_OK")

do {
    let queue = DispatchQueue(label: "test.typed-pending.primary")
    let secondary = DispatchQueue(label: "test.typed-pending.secondary")
    queue.suspend()
    let cache = TimelineAudioWaveform(worker: queue)
    let url = URL(fileURLWithPath: "/tmp/typed-pending-queues.wav")
    var primaryRan = false, secondaryRan = false
    cache.enqueueVertexForPendingTest("primary", url: url) { primaryRan = true }
    cache.enqueueNamedForPendingTest("display:secondary", url: url, queue: secondary) { secondaryRan = true }
    secondary.sync {}
    precondition(secondaryRan && !primaryRan && cache.pendingCountForTest() == 1,
                 "named display/source jobs retain their explicitly supplied worker")
    queue.resume()
    queue.sync {}
    precondition(primaryRan && cache.pendingCountForTest() == 0 && cache.version(url) == 2)
}
print("TYPED_PENDING_CUSTOM_QUEUE_ROUTING_AND_SHARED_COMPLETION_OK")

extension TimelineAudioWaveform {
    static func vertexLabelForIdentityTest(_ prefix: String, start: Int64 = 0, span: Int = 512, step: Int = 1) -> String {
        VertexKey(source: VertexSource(prefix), start: start, span: span, step: step).label
    }
}
do {
    let prefix = "/Users/Músicas/Violão/Gravação 🎹.wav:48000:48000.0:version-1"
    let label = TimelineAudioWaveform.vertexLabelForIdentityTest(prefix)
    precondition(label.utf8.allSatisfy { $0 < 128 }, "cache labels avoid per-block Unicode normalization")
    precondition(label == TimelineAudioWaveform.vertexLabelForIdentityTest(prefix.decomposedStringWithCanonicalMapping),
                 "canonical equivalent paths preserve semantic buffer reuse")
    let encoded = String(label.split(separator: ":")[1])
    precondition(Data(base64Encoded: encoded).flatMap { String(data: $0, encoding: .utf8) } == prefix,
                 "source encoding is reversible, not a collision-prone hash-only identifier")
    let different = [
        TimelineAudioWaveform.vertexLabelForIdentityTest(prefix + ":replacement"),
        TimelineAudioWaveform.vertexLabelForIdentityTest(prefix.replacingOccurrences(of: "Violão", with: "Violino")),
        TimelineAudioWaveform.vertexLabelForIdentityTest(prefix, start: 512),
        TimelineAudioWaveform.vertexLabelForIdentityTest(prefix, span: 768),
        TimelineAudioWaveform.vertexLabelForIdentityTest(prefix, step: 2)
    ]
    precondition(!different.contains(label) && Set(different).count == different.count,
                 "source version and every block coordinate retain separate GPU cache identities")
}
print("VERTEX_ASCII_LABELS_CANONICAL_UNICODE_REVERSIBLE_SOURCE_VERSION_AND_COORDINATES_OK")

extension WaveformSource {
    func referencePeakVerticesForTest(start: Int64, step: Int, span: Int, key: String) -> TimelineAudioWaveform.VertexBlock {
        let step = max(Self.baseStep, step)
        let remaining = max(0, min(Int64(span), frames - start))
        let count = Int((remaining + Int64(step) - 1) / Int64(step))
        let level = levels.last { $0.step <= step }
        let sourceStep = level?.step ?? Self.baseStep
        let data = level?.samples ?? samples
        var points = Array(repeating: [SIMD2<Float>](), count: channels)
        for channel in 0..<channels { points[channel].reserveCapacity(count * 2) }
        data.withUnsafeBytes { raw in
            for bucket in 0..<count {
                let first = (Int(start) + bucket * step) / sourceStep
                let last = min(Int((frames + Int64(sourceStep) - 1) / Int64(sourceStep)), first + step / sourceStep)
                for channel in 0..<channels {
                    var maximum = Int16.min, minimum = Int16.max
                    for source in first..<last {
                        let offset = (source * channels + channel) * Self.recordBytes
                        guard offset + Self.recordBytes <= raw.count else { continue }
                        maximum = max(maximum, Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self)))
                        minimum = min(minimum, Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 2, as: Int16.self)))
                    }
                    // Each pair describes the full interval rectangle. Clipping
                    // a one-sample item inside a peak interval keeps it visible.
                    let firstX = Float(bucket * step)
                    let lastX = Float(min(remaining, Int64((bucket + 1) * step)))
                    let high = -WaveformPeakCodec.decode(maximum), low = -WaveformPeakCodec.decode(minimum)
                    points[channel].append(SIMD2(firstX, high))
                    points[channel].append(SIMD2(lastX, low))
                }
            }
        }
        return TimelineAudioWaveform.VertexBlock(channels: points, start: start,
            end: start + remaining, step: step, rate: rate, key: key, isPeakEnvelope: true)
    }

    static func peakChannelOrderFixture(frames: Int64, channels: Int) -> WaveformSource {
        let count = Int((frames + 255) / 256)
        var data = Data(count: count * channels * 4)
        data.withUnsafeMutableBytes { raw in
            for index in 0..<count {
                for channel in 0..<channels {
                    let a = Int16(truncatingIfNeeded: index &* 2654435761 &+ channel &* 134775813)
                    let b = Int16(truncatingIfNeeded: index &* 214013 &+ channel &* 2531011)
                    let offset = (index * channels + channel) * 4
                    raw.storeBytes(of: max(a, b).littleEndian, toByteOffset: offset, as: Int16.self)
                    raw.storeBytes(of: min(a, b).littleEndian, toByteOffset: offset + 2, as: Int16.self)
                }
            }
        }
        return WaveformSource(samples: data, rate: 48_000, frames: frames, channels: channels)
    }
}

var peakChannelOrderCases = 0
for channels in [1, 3] {
    for frames: Int64 in [1, 257, 130_073] {
        let source = WaveformSource.peakChannelOrderFixture(frames: frames, channels: channels)
        // Stored 4x levels and the intermediate 2x requests use the same exact
        // signed extrema; include partial and empty final blocks at each level.
        for step in [256, 512, 1024, 2048, 16384, 32768] {
            for start: Int64 in [0, min(257, frames), max(0, frames - 1), frames] {
                let span = max(512, step * 128)
                let key = "channel-order:\(channels):\(frames):\(step):\(start)"
                let reference = source.referencePeakVerticesForTest(start: start, step: step, span: span, key: key)
                let value = source.vertices(start: start, step: step, span: span, key: key)
                precondition(exactBits(reference.channels, value.channels),
                             "coarse channel traversal preserves every vertex bit, signed peak and endpoint")
                precondition(value.start == reference.start && value.end == reference.end &&
                             value.step == reference.step && value.rate == reference.rate &&
                             value.key == reference.key && value.keyHash == reference.keyHash && value.isPeakEnvelope)
                peakChannelOrderCases += 1
            }
        }
    }
}
print("COARSE_CHANNEL_TRAVERSAL_BIT_EXACT_\(peakChannelOrderCases)_STORED_AND_INTERMEDIATE_LEVELS_MONO_STEREO_MIX_AND_EOF_OK")


func retainedTestBuffer(channels: Int, capacity: Int, frames: Int, interleaved: Bool = false) -> AVAudioPCMBuffer {
    let format: AVAudioFormat
    if channels == 4 {
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Quadraphonic)!
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, interleaved: interleaved, channelLayout: layout)
    } else {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: AVAudioChannelCount(channels), interleaved: interleaved)!
    }
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(capacity))!
    buffer.frameLength = AVAudioFrameCount(frames)
    let values: [Float] = [0, -0.0, 0.5, -0.25, Float(bitPattern: 0x7fc00011), .infinity, -.infinity, 1, -1]
    for channel in 0..<channels {
        for frame in 0..<frames {
            let value = values[(frame + channel) % values.count]
            if interleaved { buffer.floatChannelData![0][frame * channels + channel] = value }
            else { buffer.floatChannelData![channel][frame] = value }
        }
    }
    return buffer
}
func retainedCopyReference(_ buffer: AVAudioPCMBuffer, frames: Int) -> TimelineAudioWaveform.PCM {
    let decoded = Int(buffer.frameLength), count = Int(buffer.format.channelCount)
    return TimelineAudioWaveform.PCM(channels: (0..<count).map { channel in
        (0..<frames).map { index in
            guard index < decoded else { return Float.zero }
            return buffer.format.isInterleaved
                ? buffer.floatChannelData![0][index * count + channel]
                : buffer.floatChannelData![channel][index]
        }
    })
}
var retainedCases = 0
for channelCount in [1, 2, 4] {
    for capacity in [17, 8192] {
        for frames in [1, capacity - 3, capacity] {
            let buffer = retainedTestBuffer(channels: channelCount, capacity: capacity, frames: frames)
            let retained = TimelineAudioWaveform.PCM(retaining: buffer, frames: frames)!
            let reference = retainedCopyReference(buffer, frames: frames)
            let rawBytes = capacity * channelCount * MemoryLayout<Float>.stride
            let monoBytes = channelCount > 1 ? frames * MemoryLayout<Float>.stride : 0
            let extremaBytes = (frames / 8) * MemoryLayout<SIMD2<UInt8>>.stride * (channelCount > 1 ? channelCount + 1 : 1)
            precondition(retained.cost == rawBytes + monoBytes + extremaBytes,
                "retain decoder capacity and reserve lazy extrema without growing the cache budget")
            for channel in retained.channels.indices {
                let base = retained.channels[channel].withUnsafeBufferPointer { $0.baseAddress }
                precondition(base == UnsafePointer(buffer.floatChannelData![channel]), "decoded channel is zero-copy")
                precondition(retained.channels[channel].count == frames)
                for index in 0..<frames {
                    precondition(retained.channels[channel][index].bitPattern == reference.channels[channel][index].bitPattern)
                }
                precondition(Array(retained.channels[channel][0..<min(3, frames)]).count == min(3, frames))
            }
            for step in detailStepsExact {
                let span = max(512, step * 128)
                let before = TimelineAudioWaveform.VertexBlock(pcm: reference, start: 0, span: span, step: step, rate: 48000, key: "retained-reference")
                let after = TimelineAudioWaveform.VertexBlock(pcm: retained, start: 0, span: span, step: step, rate: 48000, key: "retained-candidate")
                precondition(exactBits(before.channels, after.channels), "retained bits across LOD incl NaN/signedzero/infinity")
                precondition(before.end == after.end)
                retainedCases += 1
            }
            if channelCount > 1 {
                for index in 0..<frames {
                    precondition(retained.waveformChannels[channelCount][index].bitPattern == reference.waveformChannels[channelCount][index].bitPattern)
                }
            }
        }
    }
}
let shortMP3Buffer = retainedTestBuffer(channels: 2, capacity: 32, frames: 13)
precondition(TimelineAudioWaveform.PCM(retaining: shortMP3Buffer, frames: 32) == nil,
    "synthetic MP3 padding must use the original explicit zero-filled copy")
let padded = retainedCopyReference(shortMP3Buffer, frames: 32)
precondition(padded.channels.allSatisfy { Array($0[13..<32]).allSatisfy { $0.bitPattern == Float.zero.bitPattern } })
let interleavedRetainedTest = retainedTestBuffer(channels: 2, capacity: 32, frames: 13, interleaved: true)
precondition(interleavedRetainedTest.stride == 2)
precondition(TimelineAudioWaveform.PCM(retaining: interleavedRetainedTest, frames: 13) == nil,
    "strided channels preserve the existing deinterleaving copy")
let emptyRetainedTest = retainedTestBuffer(channels: 2, capacity: 32, frames: 0)
precondition(TimelineAudioWaveform.PCM(retaining: emptyRetainedTest, frames: 0) == nil)

weak var retainedBufferLifetime: AVAudioPCMBuffer?
var independentChannel: TimelineAudioWaveform.PCMChannel?
autoreleasepool {
    let buffer = retainedTestBuffer(channels: 2, capacity: 32, frames: 13)
    retainedBufferLifetime = buffer
    let page = TimelineAudioWaveform.PCM(retaining: buffer, frames: 13)!
    independentChannel = page.channels[0]
}
precondition(retainedBufferLifetime != nil && independentChannel![2] == 0.5,
    "extracted channel owns decoded memory after PCM itself leaves scope")
independentChannel = nil
precondition(retainedBufferLifetime == nil, "last channel releases decoder allocation")

weak var cacheRetainedBuffer: AVAudioPCMBuffer?
weak var cacheRetainedPage: TimelineAudioWaveform.PCM?
var survivingPageView: TimelineAudioWaveform.PCMView?
var survivingRetainedVertices: TimelineAudioWaveform.VertexBlock?
let retainedCache = NSCache<NSString, TimelineAudioWaveform.PCM>()
retainedCache.totalCostLimit = 48 * 1024 * 1024
autoreleasepool {
    let buffer = retainedTestBuffer(channels: 2, capacity: 8192, frames: 17)
    let page = TimelineAudioWaveform.PCM(retaining: buffer, frames: 17)!
    cacheRetainedBuffer = buffer; cacheRetainedPage = page
    retainedCache.setObject(page, forKey: "decoded", cost: page.cost)
    survivingPageView = .init(slices: [.init(page: page, range: 0..<17)])
    survivingRetainedVertices = .init(pages: survivingPageView!, start: 0, span: 16, step: 1, rate: 48000, key: "lifetime")
}
retainedCache.removeAllObjects()
precondition(cacheRetainedBuffer != nil && cacheRetainedPage != nil, "active PCMView keeps an evicted page valid")
survivingPageView = nil
precondition(cacheRetainedBuffer == nil && cacheRetainedPage == nil && survivingRetainedVertices != nil,
    "vertex data never pins source PCM after view releases it")
print("PCM_RETAINED_DECODER_\(retainedCases)_BIT_EXACT_LODS_PADDING_STRIDE_EOF_CAPACITY_BUDGET_AND_LIFETIME_OK")

extension TimelineAudioWaveform.PCMChannel {
    func hasExtremaIndexForTest() -> Bool {
        extremaLock.lock(); defer { extremaLock.unlock() }
        return storedExtrema != nil
    }
}
do {
    let raw = (0..<8195).map { Float(sin(Double($0) * 0.113)) }
    let page = TimelineAudioWaveform.PCM(channels: [raw, raw.map { -$0 }])
    let before = page.cost
    precondition(before == 8195 * 3 * 4 + (8195 / 8) * 3 * 2)
    precondition(page.waveformChannels.allSatisfy { !$0.hasExtremaIndexForTest() })
    for step in [1,2,3,4,6] {
        _ = TimelineAudioWaveform.VertexBlock(pcm: page,start:0,span:8194,step:step,rate:48000,key:"fine-no-index")
    }
    precondition(page.waveformChannels.allSatisfy { !$0.hasExtremaIndexForTest() },
        "sample-level and fine PCM levels must not pay summary construction")
    _ = TimelineAudioWaveform.VertexBlock(pcm:page,start:0,span:8194,step:192,rate:48000,key:"summary")
    precondition(page.waveformChannels.allSatisfy { $0.hasExtremaIndexForTest() })
    let identities = page.waveformChannels.map { ObjectIdentifier($0.extremaIndex()!) }
    for step in TimelineAudioWaveform.detailSteps.reversed() {
        _ = TimelineAudioWaveform.VertexBlock(pcm:page,start:0,span:8194,step:step,rate:48000,key:"reuse")
    }
    precondition(identities == page.waveformChannels.map { ObjectIdentifier($0.extremaIndex()!) })
    precondition(page.cost == before,"summary bytes are reserved before cache insertion, never hidden later")
    let tiny = TimelineAudioWaveform.PCMChannel([1,2,3])
    precondition(tiny.extremaIndex() == nil && tiny.extremaReservedBytes == 0)
    let concurrent = TimelineAudioWaveform.PCMChannel(raw)
    let resultLock = NSLock()
    var concurrentIDs = Set<ObjectIdentifier>()
    DispatchQueue.concurrentPerform(iterations:16) { _ in
        let id = ObjectIdentifier(concurrent.extremaIndex()!)
        resultLock.lock(); concurrentIDs.insert(id); resultLock.unlock()
    }
    precondition(concurrentIDs.count == 1,"concurrent readers publish one immutable summary")
}
var extremaSummaryCases = 0
let summaryNaN = Float(bitPattern:0x7fc00013)
let summaryPatterns: [[Float]] = [
    Array(repeating:summaryNaN,count:257),
    (0..<257).map { [summaryNaN,summaryNaN,Float.infinity,-Float.infinity,Float(-0.0),Float(0.0),Float(1),Float(-1)][$0 % 8] },
    (0..<257).map { $0 % 17 == 0 ? summaryNaN : ($0 % 2 == 0 ? Float(-0.0) : Float(0.0)) },
    (0..<257).map { $0 == 16 || $0 == 113 || $0 == 128 ? Float(-1) : Float(1) }
]
for samples in summaryPatterns {
    let channels = [samples,samples.map { -$0 }]
    for pageFrames in [8,17,113] {
        let pages = makePages(channels,pageFrames:pageFrames)
        for offset in [0,1,7,8,16] {
            let source = channels.map { Array($0[offset..<samples.count]) }
            let view = makeView(pages,pageFrames:pageFrames,range:offset..<samples.count)
            for step in TimelineAudioWaveform.detailSteps + [9,17,193] {
                let candidate=TimelineAudioWaveform.VertexBlock(pages:view,start:Int64(offset),span:samples.count-offset-1,step:step,rate:48000,key:"summary-exact")
                precondition(exactBits(candidate.channels,referenceVertices(source,span:samples.count-offset-1,step:step)),
                    "summary must preserve ties, NaN payloads, infinities and signed zero across partial groups/pages")
                extremaSummaryCases += 1
            }
        }
    }
}
print("PCM_LAZY_EXTREMA_\(extremaSummaryCases)_BIT_EXACT_CASES_REUSE_THREADSAFE_PUBLICATION_AND_RESERVED_BUDGET_OK")
