import SwiftUI
import AVFoundation
import Accelerate
import Darwin

/// The signed 16-bit RPKL peak scale documented by Cockos. Drawing caches
/// retain two values per interval; audio playback never uses quantized peaks.
enum WaveformPeakCodec {
    static func encode(_ value: Float) -> Int16 {
        guard value.isFinite else { return 0 }
        let magnitude = abs(value)
        let encoded = magnitude <= 1 ? magnitude * 24576 : 24576 + 1024 * log2(magnitude)
        return Int16(max(-32768, min(32767, (value < 0 ? -encoded : encoded).rounded())))
    }
    static func decode(_ value: Int16) -> Float {
        let magnitude = abs(Int(value))
        let decoded = magnitude <= 24576 ? Float(magnitude) / 24576 : exp2(Float(magnitude - 24576) / 1024)
        return value < 0 ? -decoded : decoded
    }
}

/// Project peak indices and a small complete overview are prepared before display.
/// Unprepared/live sources use viewport blocks independently of playback.
/// Immutable source geometry is shared by duplicates and zoom levels.
final class TimelineAudioWaveform: ObservableObject {
    static let shared = TimelineAudioWaveform()
    static let blockFrames = 65_536
    static func diskCacheURL(_ url: URL) -> URL { WaveformSource.cacheURL(url) }
    @Published private(set) var revision: UInt64 = 0

    final class Header: NSObject {
        let rate: Double
        let frames: Int64
        let channels: Int
        let sourcePath: String?
        let cachePrefix: String?
        let checkedAt = ProcessInfo.processInfo.systemUptime
        init(rate: Double, frames: Int64, channels: Int = 1, sourcePath: String? = nil, sourceVersion: String? = nil) {
            self.rate = rate; self.frames = frames; self.channels = channels
            self.sourcePath = sourcePath
            cachePrefix = sourcePath.map { "\($0):\(frames):\(rate):\(sourceVersion ?? "")" }
        }
    }
    final class PCM: NSObject {
        let channels: [[Float]]
        init(channels: [[Float]]) { self.channels = channels }
    }
    /// Keep extrema at their actual sample positions, in time order. A coarser
    /// level removes subpixel detail; it never moves a peak to a bucket boundary.
    struct Sample {
        let frame: Int
        let value: Float
    }
    struct Bucket {
        var first: Sample?
        var last: Sample?
        var minimum: Sample?
        var maximum: Sample?
        mutating func include(first: Sample, last: Sample, minimum: Sample, maximum: Sample) {
            if self.first == nil { self.first = first }
            self.last = last
            if self.minimum == nil || minimum.value < self.minimum!.value { self.minimum = minimum }
            if self.maximum == nil || maximum.value > self.maximum!.value { self.maximum = maximum }
        }
        func append(to path: inout Path, rate: Double, previous: inout Int, final: Bool) {
            guard let first, let last, let minimum, let maximum else { return }
            func append(_ sample: Sample) {
                guard sample.frame > previous else { return }
                let point = CGPoint(x: Double(sample.frame) / rate, y: -CGFloat(sample.value))
                if previous < 0 { path.move(to: point) } else { path.addLine(to: point) }
                previous = sample.frame
            }
            append(first)
            if minimum.frame < maximum.frame { append(minimum); append(maximum) }
            else { append(maximum); append(minimum) }
            append(last)
        }
    }
    final class Geometry: NSObject {
        let paths: [Path]
        let step: Int
        let start: Int64
        let end: Int64
        let rate: Double
        let cost: Int
        let isPeakEnvelope: Bool
        init(vertices: VertexBlock) {
            isPeakEnvelope = vertices.isPeakEnvelope
            step = vertices.step; start = vertices.start; end = vertices.end; rate = vertices.rate
            cost = vertices.cost * 3
            paths = vertices.channels.map { points in
                var path = Path()
                if vertices.isPeakEnvelope {
                    for index in stride(from: 0, to: points.count - 1, by: 2) {
                        let a = points[index], b = points[index + 1]
                        path.addRect(CGRect(x: Double(a.x) / vertices.rate, y: Double(min(a.y, b.y)),
                            width: Double(b.x - a.x) / vertices.rate, height: Double(abs(b.y - a.y))))
                    }
                    return path
                }
                for (index, point) in points.enumerated() {
                    let value = CGPoint(x: Double(point.x) / vertices.rate, y: Double(point.y))
                    if index == 0 { path.move(to: value) } else { path.addLine(to: value) }
                }
                return path
            }
        }
        init(buckets: [[Bucket]], start: Int64, rate: Double, frames: Int64, span: Int, step: Int) {
            isPeakEnvelope = false
            self.step = step
            self.start = start; self.end = start + min(Int64(span), frames); self.rate = rate
            cost = buckets.reduce(0) { $0 + $1.count * 4 * 24 }
            paths = buckets.map { channel in
                var path = Path(), previous = -1
                for (index, bucket) in channel.enumerated() { bucket.append(to: &path, rate: rate, previous: &previous, final: index == channel.count - 1) }
                return path
            }
        }
        init(pcm: PCM, start: Int64, rate: Double, step: Int, span: Int) {
            isPeakEnvelope = false
            self.step = step
            self.start = start; self.end = start + Int64(min(span, pcm.channels.first?.count ?? 0)); self.rate = rate
            cost = pcm.channels.count * (span / step + 2) * (step == 1 ? 24 : 96)
            let channels = pcm.channels.count > 1 ? pcm.channels + [zip(pcm.channels[0], pcm.channels[1]).map { ($0 + $1) * 0.5 }] : pcm.channels
            paths = channels.map { source in
                // Share exactly one source sample with the next block.
                let count = min(source.count, span + 1)
                var path = Path(), previous = -1
                guard count > 0 else { return path }
                if step == 1 {
                    path.move(to: CGPoint(x: 0, y: -CGFloat(source[0])))
                    for index in 1..<count {
                        path.addLine(to: CGPoint(x: Double(index) / rate, y: -CGFloat(source[index])))
                    }
                } else {
                    for index in stride(from: 0, to: count, by: step) {
                        let last = min(count, index + step) - 1
                        var low = index, high = index
                        for frame in index...last {
                            if source[frame] < source[low] { low = frame }
                            if source[frame] > source[high] { high = frame }
                        }
                        let bucket = Bucket(first: Sample(frame: index, value: source[index]), last: Sample(frame: last, value: source[last]), minimum: Sample(frame: low, value: source[low]), maximum: Sample(frame: high, value: source[high]))
                        bucket.append(to: &path, rate: rate, previous: &previous, final: last == count - 1)
                    }
                }
                return path
            }
        }
    }

    /// GPU-ready source data. These vertices are prepared once on a worker and
    /// shared by every instance of an audio source; zoom only changes uniforms.
    /// x is a frame offset relative to `start`, y is the signed inverted sample.
    final class VertexBlock: NSObject {
        let channels: [[SIMD2<Float>]]
        let start: Int64
        let end: Int64
        let step: Int
        let rate: Double
        let key: String
        let isPeakEnvelope: Bool
        var cost: Int { channels.reduce(0) { $0 + $1.count * MemoryLayout<SIMD2<Float>>.stride } }

        init(channels: [[SIMD2<Float>]], start: Int64, end: Int64, step: Int, rate: Double, key: String, isPeakEnvelope: Bool = false) {
            self.isPeakEnvelope = isPeakEnvelope
            self.channels = channels.map { points in
                if isPeakEnvelope { return points }
                // Silence and constant plateaus have one exact straight segment;
                // retaining thousands of coincident capsules wastes GPU fill when
                // many items become visible while zooming out.
                guard points.count > 2 else { return points }
                var result: [SIMD2<Float>] = []; result.reserveCapacity(min(points.count, 256))
                for point in points {
                    if result.count >= 2, result[result.count - 1].y == point.y, result[result.count - 2].y == point.y {
                        result[result.count - 1] = point
                    } else { result.append(point) }
                }
                // Release unused storage for silent blocks as well as vertices.
                return result.count < points.count / 2 ? result.withUnsafeBufferPointer { Array($0) } : result
            }
            self.start = start; self.end = end
            self.step = step; self.rate = rate; self.key = key
        }
        convenience init(buckets: [[Bucket]], start: Int64, end: Int64, step: Int, rate: Double, key: String) {
            let channels = buckets.map { buckets -> [SIMD2<Float>] in
                var vertices: [SIMD2<Float>] = []
                vertices.reserveCapacity(buckets.count * 4)
                var previous = -1
                func append(_ sample: Sample?) {
                    guard let sample, sample.frame > previous else { return }
                    vertices.append(SIMD2(Float(sample.frame), -sample.value)); previous = sample.frame
                }
                for bucket in buckets {
                    append(bucket.first)
                    if let low = bucket.minimum, let high = bucket.maximum {
                        if low.frame < high.frame { append(low); append(high) }
                        else { append(high); append(low) }
                    }
                    append(bucket.last)
                }
                return vertices
            }
            self.init(channels: channels, start: start, end: end, step: step, rate: rate, key: key)
        }
        convenience init(pcm: PCM, start: Int64, span: Int, step: Int, rate: Double, key: String) {
            let sourceChannels = pcm.channels.count > 1
                ? pcm.channels + [zip(pcm.channels[0], pcm.channels[1]).map { ($0 + $1) * 0.5 }]
                : pcm.channels
            let channels = sourceChannels.map { source -> [SIMD2<Float>] in
                let count = min(source.count, span + 1)
                guard count > 0 else { return [] }
                if step == 1 { return (0..<count).map { SIMD2(Float($0), -source[$0]) } }
                var vertices: [SIMD2<Float>] = []
                vertices.reserveCapacity((count / step + 1) * 4)
                var previous = -1
                func append(_ frame: Int) {
                    guard frame > previous else { return }
                    vertices.append(SIMD2(Float(frame), -source[frame])); previous = frame
                }
                for first in stride(from: 0, to: count, by: step) {
                    let last = min(count, first + step) - 1
                    var low = first, high = first
                    for frame in first...last {
                        if source[frame] < source[low] { low = frame }
                        if source[frame] > source[high] { high = frame }
                    }
                    append(first)
                    if low < high { append(low); append(high) } else { append(high); append(low) }
                    append(last)
                }
                return vertices
            }
            self.init(channels: channels, start: start, end: start + Int64(min(span, pcm.channels.first?.count ?? 0)), step: step, rate: rate, key: key)
        }
    }
    struct VertexDrawing {
        let blocks: [VertexBlock]
        let complete: Bool
        let requestedStep: Int
    }

    private let vertexBlocks = NSCache<NSString, VertexBlock>()
    private let headers = NSCache<NSString, Header>()
    private let pcm = NSCache<NSString, PCM>()
    private let geometries = NSCache<NSString, Geometry>()
    private let joinedDrawings = NSCache<NSString, RetainedDrawing>()
    // Weak entries point into the existing byte-bounded drawing caches. They
    // never retain an extra waveform merely because the viewport once used it.
    private let coverageLock = NSLock()
    private var coverageDrawings: [String: [DrawingCoverage]] = [:]
    private final class VertexOverview: NSObject {
        let levels: [Int: [VertexBlock]]
        var cost: Int { levels.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.cost } } }
        init(_ levels: [Int: [VertexBlock]]) { self.levels = levels }
    }
    // Keep complete lightweight source overviews independently of detail-block
    // churn, so a zoom never exposes audio one newly decoded block at a time.
    private let vertexOverviews = NSCache<NSString, VertexOverview>()
    private let projectCacheLock = NSLock()
    private var projectHeaders: [String: Header] = [:]
    private var projectOverviews: [String: VertexOverview] = [:]
    private var projectSources: [String: WaveformSource] = [:]
    private func pinnedSource(_ prefix: String) -> WaveformSource? {
        projectCacheLock.lock(); defer { projectCacheLock.unlock() }
        return projectSources[prefix]
    }
    private func pinnedHeader(_ path: String) -> Header? {
        projectCacheLock.lock(); defer { projectCacheLock.unlock() }
        return projectHeaders[path]
    }
    private func pinnedOverview(_ prefix: String) -> VertexOverview? {
        projectCacheLock.lock(); defer { projectCacheLock.unlock() }
        return projectOverviews[prefix]
    }
    private func installProjectCache(headers: [String: Header], overviews: [String: VertexOverview], sources: [String: WaveformSource]) {
        projectCacheLock.lock(); defer { projectCacheLock.unlock() }
        projectHeaders = headers; projectOverviews = overviews
        projectSources = sources
    }
    /// Map compact .waveform peak levels and prepare a complete small overview.
    /// Detailed pages remain reclaimable file-backed memory; only visible GPU
    /// blocks occupy the bounded drawing cache.
    @MainActor func preload(_ urls: [URL], progress: @escaping @MainActor (Int, Int) -> Void = { _, _ in }) async {
        let files = Array(Set(urls.map { $0.standardizedFileURL })).sorted { $0.path < $1.path }
        // A complete fallback for every file fits a project-wide 32 MiB target.
        // It remains available when detailed vertex blocks are evicted.
        let overviewPixels = max(16, min(512, (32 * 1024 * 1024) / max(1, files.count) / 384))
        let prepared: ([String: Header], [String: VertexOverview], [String: WaveformSource]) = await withCheckedContinuation { continuation in
            sourceWorker.async { [self] in
                var preparedHeaders: [String: Header] = [:], preparedOverviews: [String: VertexOverview] = [:]
                var preparedSources: [String: WaveformSource] = [:]
                for (index, url) in files.enumerated() {
                    autoreleasepool {
                        guard let audio = try? AVAudioFile(forReading: url) else { return }
                        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
                        let header = Header(rate: audio.processingFormat.sampleRate, frames: audio.length,
                            channels: Int(audio.processingFormat.channelCount), sourcePath: url.path, sourceVersion: "\(size):\(modified)")
                        guard let prefix = header.cachePrefix, let source = try? (pinnedSource(prefix) ?? WaveformSource.loadOrBuild(url, header: header)),
                              let overview = prepareZoomOutVertices(source, header: header, prefix: prefix, overviewPixels: overviewPixels) else { return }
                        preparedHeaders[url.path] = header; preparedOverviews[prefix] = overview
                        preparedSources[prefix] = source
                        headers.setObject(header, forKey: url.path as NSString)
                        sources.setObject(source, forKey: prefix as NSString, cost: source.cost)
                    }
                    if index % 16 == 0 || index + 1 == files.count {
                        DispatchQueue.main.async { progress(index + 1, files.count) }
                    }
                }
                continuation.resume(returning: (preparedHeaders, preparedOverviews, preparedSources))
            }
        }
        installProjectCache(headers: prepared.0, overviews: prepared.1, sources: prepared.2)
        revision &+= 1
    }
    private let sources = NSCache<NSString, WaveformSource>()
    private let sourceWorker = DispatchQueue(label: "jaras.waveform.prepare", qos: .utility)
    private var fileVersions: [String: UInt64] = [:]
    private let worker: DispatchQueue
    private let drawingWorker: DispatchQueue
    private let presentations = NSCache<NSString, WaveformPresentation>()
    private final class WeakPresentation {
        weak var value: WaveformPresentation?
        init(_ value: WaveformPresentation) { self.value = value }
    }
    private let presentationIndexLock = NSLock()
    private var presentationIndex: [String: [WeakPresentation]] = [:]
    private static let emptyDrawing = Drawing(values: [], step: 1)
    private let retained = NSCache<NSString, RetainedDrawing>()
    private let lock = NSLock()
    private var pending = Set<String>()
    private var notificationPending = false
    private var readyLevels: [String: Set<Int>] = [:]
    private var files: [String: AVAudioFile] = [:] // Accessed only by worker.

    init(worker: DispatchQueue = DispatchQueue(label: "jaras.waveform.decode", qos: .utility), drawingWorker: DispatchQueue = DispatchQueue(label: "jaras.waveform.curves", qos: .userInitiated), presentationCacheCostLimit: Int = 64 * 1024 * 1024) {
        self.worker = worker
        self.drawingWorker = drawingWorker
        // Keep the visible curve independently of lower-level preparation.
        presentations.totalCostLimit = presentationCacheCostLimit
        sources.totalCostLimit = 48 * 1024 * 1024
        vertexBlocks.totalCostLimit = 64 * 1024 * 1024
        vertexOverviews.totalCostLimit = 32 * 1024 * 1024
        headers.countLimit = 512
        pcm.totalCostLimit = 48 * 1024 * 1024
        geometries.totalCostLimit = 24 * 1024 * 1024
        // Bound bytes, not tile count: a wide viewport can need more than 512
        // small tiles, and evicting those while still visible causes reloads.
        retained.totalCostLimit = 16 * 1024 * 1024
        joinedDrawings.totalCostLimit = 16 * 1024 * 1024
    }

    func header(_ url: URL, refresh: Bool = false) -> Header? {
        let url = url.standardizedFileURL
        let key = url.path as NSString
        let previous = headers.object(forKey: key) ?? pinnedHeader(url.path)
        if let value = previous, !refresh || ProcessInfo.processInfo.systemUptime - value.checkedAt < 1 {
            return value.rate > 0 ? value : nil
        }
        enqueue("header:\(url.path)", url: url) { [self] in
            if refresh { files.removeValue(forKey: url.path) }
            if let audio = try? file(url) {
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
                let value = Header(rate: audio.processingFormat.sampleRate, frames: audio.length, channels: Int(audio.processingFormat.channelCount), sourcePath: key as String, sourceVersion: "\(size):\(modified)")
                headers.setObject(value, forKey: key)
                return previous?.cachePrefix != value.cachePrefix || previous?.channels != value.channels
            } else {
                headers.setObject(Header(rate: 0, frames: 0), forKey: key)
                return false
            }
        }
        return previous.flatMap { $0.rate > 0 ? $0 : nil }
    }

    func geometry(_ url: URL, header: Header, block: Int, pixelsPerSecond: Double) -> Geometry? {
        let step = Self.step(rate: header.rate, pixelsPerSecond: pixelsPerSecond)
        let span = Self.span(step: step)
        let prefix = header.cachePrefix ?? "\(url.path):\(header.frames)"
        let rawKey = "\(prefix):\(block * span):\(span)"
        let key = "\(rawKey):\(step)" as NSString
        if let value = geometries.object(forKey: key) { return value }
        let sourceKey = prefix as NSString
        let prepared = step >= WaveformSource.baseStep ? sources.object(forKey: sourceKey) : nil
        if step >= WaveformSource.baseStep, prepared == nil {
            prepareSource(url, header: header)
            return nil
        }
        enqueue("geometry:\(key)", url: url) { [self] in
            defer {
                if geometries.object(forKey: key) == nil {
                    geometries.setObject(Geometry(pcm: PCM(channels: []), start: 0, rate: header.rate, step: step, span: span), forKey: key)
                }
            }
            let start = Int64(block) * Int64(span)
            guard start < header.frames else { return false }
            if let prepared {
                let value = prepared.geometry(start: start, step: step, span: span)
                geometries.setObject(value, forKey: key, cost: value.cost)
                registerLevel(prefix, step: step)
                return true
            }
            guard let data = readPCM(url, header: header, start: start, span: span, key: rawKey) else { return false }
            let value = Geometry(pcm: data, start: start, rate: header.rate, step: step, span: span)
            geometries.setObject(value, forKey: key, cost: value.cost)
            registerLevel(prefix, step: step)
            return true
        }
        return nil
    }

    /// Nonblocking, viewport-only GPU lookup. Missing blocks are queued; the
    /// renderer owns the last complete visible drawing until replacement is ready.
    /// Prepared projects copy the requested peak level from RAM in one frame;
    /// no audio read, background refinement or pyramid reduction runs here.
    func vertexDrawing(_ url: URL, header: Header, start: Double, end: Double, pixelsPerSecond: Double) -> VertexDrawing {
        guard header.rate > 0, header.frames > 0, start.isFinite, end.isFinite,
              pixelsPerSecond.isFinite, pixelsPerSecond > 0 else {
            return VertexDrawing(blocks: [], complete: false, requestedStep: 1)
        }
        let step = Self.step(rate: header.rate, pixelsPerSecond: pixelsPerSecond)
        let firstFrame = max(0, min(Double(header.frames), start * header.rate))
        let lastFrame = max(firstFrame, min(Double(header.frames), end * header.rate))
        guard lastFrame > firstFrame else { return VertexDrawing(blocks: [], complete: true, requestedStep: step) }
        let span = Self.span(step: step)
        let first = Int(floor(firstFrame / Double(span)))
        // Source intervals move by fractional samples during zoom. Subtracting
        // a whole sample here can omit the next block and never reach complete.
        let last = max(first, Int(ceil(lastFrame / Double(span))) - 1)
        let prefix = header.cachePrefix ?? "\(url.path):\(header.frames)"
        if let source = pinnedSource(prefix) {
            let preparedStep = max(WaveformSource.baseStep, step)
            if let blocks = pinnedOverview(prefix)?.levels[preparedStep] {
                return VertexDrawing(blocks: blocks.filter { Double($0.end) > firstFrame && Double($0.start) < lastFrame }, complete: true, requestedStep: step)
            }
            let preparedSpan = Self.span(step: preparedStep)
            let first = Int(floor(firstFrame / Double(preparedSpan)))
            let last = max(first, Int(ceil(lastFrame / Double(preparedSpan))) - 1)
            var blocks: [VertexBlock] = []
            for index in first...last {
                let start = Int64(index) * Int64(preparedSpan)
                let key = "vertices:\(prefix):\(start):\(preparedSpan):\(preparedStep)"
                if let hit = vertexBlocks.object(forKey: key as NSString) { blocks.append(hit); continue }
                let block = source.vertices(start: start, step: preparedStep, span: preparedSpan, key: key)
                vertexBlocks.setObject(block, forKey: key as NSString, cost: block.cost)
                blocks.append(block)
            }
            return VertexDrawing(blocks: blocks, complete: true, requestedStep: step)
        }
        let source = step >= WaveformSource.baseStep ? sources.object(forKey: prefix as NSString) : nil
        var needsSource = false
        var ready: [VertexBlock] = []
        // A malicious or obsolete viewport request must not enqueue an entire
        // project. Normal viewports need only a few dozen fixed-detail blocks.
        let boundedLast = min(last, first + 511)
        ready.reserveCapacity(min(512, last - first + 1))
        for block in first...boundedLast {
            let start = Int64(block) * Int64(span)
            let rawKey = "\(prefix):\(start):\(span)"
            let key = "vertices:\(rawKey):\(step)"
            if let value = vertexBlocks.object(forKey: key as NSString) { ready.append(value); continue }
            if step >= WaveformSource.baseStep, source == nil { needsSource = true; continue }
            enqueue(key, url: url) { [self] in
                let value: VertexBlock
                if let source {
                    value = source.vertices(start: start, step: step, span: span, key: key)
                } else {
                    guard let data = readPCM(url, header: header, start: start, span: span, key: rawKey) else { return false }
                    value = VertexBlock(pcm: data, start: start, span: span, step: step, rate: header.rate, key: key)
                }
                guard !value.channels.isEmpty else { return false }
                vertexBlocks.setObject(value, forKey: key as NSString, cost: value.cost)
                return true
            }
        }
        // A warm vertex lookup must not reload a (possibly evicted) multi-MB
        // source pyramid. That caused repeated I/O and global redraws on zoom.
        if needsSource { prepareSource(url, header: header) }
        let complete = last == boundedLast && ready.count == last - first + 1 &&
            ready.first.map { Double($0.start) <= firstFrame } == true &&
            ready.last.map { Double($0.end) >= lastFrame } == true
        return VertexDrawing(blocks: ready, complete: complete, requestedStep: step)
    }

    /// Find an already prepared zoom-out level without scheduling or reading.
    /// Used only while the requested detail is pending, to bound GPU work when
    /// shrinking a previously very detailed source into a few screen pixels.
    func cachedCoarserVertices(_ header: Header, url: URL, start: Double, end: Double,
                               requestedStep: Int) -> [VertexBlock] {
        let prefix = header.cachePrefix ?? "\(url.path):\(header.frames)"
        let firstFrame = max(0, start * header.rate), lastFrame = min(Double(header.frames), end * header.rate)
        guard lastFrame > firstFrame else { return [] }
        var step = max(WaveformSource.baseStep, requestedStep)
        while step <= 1 << 26 {
            if let overview = (pinnedOverview(prefix) ?? vertexOverviews.object(forKey: prefix as NSString))?.levels[step] {
                let visible = overview.filter { Double($0.end) >= firstFrame && Double($0.start) <= lastFrame }
                if visible.first.map({ Double($0.start) <= firstFrame }) == true,
                   visible.last.map({ Double($0.end) >= lastFrame }) == true { return visible }
            }
            let span = Self.span(step: step)
            let first = Int(firstFrame / Double(span)), last = Int(ceil(lastFrame / Double(span))) - 1
            if last >= first, last - first < 64 {
                var result: [VertexBlock] = []
                for index in first...last {
                    let key = "vertices:\(prefix):\(Int64(index) * Int64(span)):\(span):\(step)"
                    guard let value = vertexBlocks.object(forKey: key as NSString) else { result.removeAll(); break }
                    result.append(value)
                }
                if !result.isEmpty { return result }
            }
            step *= 2
        }
        return []
    }

    private func prepareZoomOutVertices(_ source: WaveformSource, header: Header, prefix: String, startingStep: Int? = nil, overviewPixels: Int = 512) -> VertexOverview? {
        let duration = Double(header.frames) / header.rate
        guard duration > 0 else { return nil }
        // Project opening prepares the complete peak pyramid from its base
        // resolution. Unprepared sources use a small overview while loading.
        var overview: [Int: [VertexBlock]] = [:]
        var step = startingStep ?? max(WaveformSource.baseStep, Self.step(rate: header.rate, pixelsPerSecond: Double(overviewPixels) / duration))
        while step <= 1 << 26 {
            let span = Self.span(step: step)
            for start in stride(from: Int64(0), to: header.frames, by: span) {
                let key = "vertices:\(prefix):\(start):\(span):\(step)"
                if let hit = vertexBlocks.object(forKey: key as NSString) {
                    overview[step, default: []].append(hit); continue
                }
                let block = source.vertices(start: start, step: step, span: span, key: key)
                vertexBlocks.setObject(block, forKey: key as NSString, cost: block.cost)
                overview[step, default: []].append(block)
            }
            if Int64(step) >= header.frames { break }
            step *= 2
        }
        let value = VertexOverview(overview)
        vertexOverviews.setObject(value, forKey: prefix as NSString, cost: value.cost)
        return value
    }

    /// Shared PCM pages are decoder-owned, never accessed from the render thread.
    private func readPCM(_ url: URL, header: Header, start: Int64, span: Int, key: String) -> PCM? {
        if let value = pcm.object(forKey: key as NSString) { return value }
        guard start >= 0, start < header.frames, let audio = try? file(url) else { return nil }
        let count = AVAudioFrameCount(min(Int64(span + 512), header.frames - start))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: count) else { return nil }
        do { audio.framePosition = start; try audio.read(into: buffer, frameCount: count) }
        catch { return nil }
        guard let pointers = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
        let frames = Int(buffer.frameLength), stride = buffer.stride
        let data = PCM(channels: (0..<Int(buffer.format.channelCount)).map { channel in
            (0..<frames).map { pointers[channel][$0 * stride] }
        })
        pcm.setObject(data, forKey: key as NSString, cost: frames * data.channels.count * 4)
        return data
    }

    struct Drawing {
        let values: [Geometry]
        let step: Int
        let origin: Int64
        let paths: [Path]
        let cgPaths: [CGPath]
        /// Endpoints alone do not prove coverage: asynchronous block loading
        /// can leave holes between them. Never pin that as a finished waveform.
        func covers(start: Double, end: Double, rate: Double) -> Bool {
            let firstFrame = start * rate, lastFrame = end * rate - 1
            var covered = firstFrame
            for geometry in values {
                guard Double(geometry.start) <= covered + 0.001 else { return false }
                covered = max(covered, Double(geometry.end))
                if covered >= lastFrame { return true }
            }
            return false
        }
        init(values: [Geometry], step: Int) {
            self.values = values; self.step = step
            origin = values.first?.start ?? 0
            let origin = origin
            cgPaths = (0..<(values.first?.paths.count ?? 0)).map { channel in
                let path = CGMutablePath()
                if values.contains(where: \.isPeakEnvelope) {
                    for geometry in values where channel < geometry.paths.count {
                        path.addPath(geometry.paths[channel].cgPath,
                            transform: CGAffineTransform(translationX: Double(geometry.start - origin) / geometry.rate, y: 0))
                    }
                    return path.copy()!
                }
                var lastX = -Double.infinity, previousEnd: Int64?
                // Keep both ends of an exactly horizontal run. Intermediate
                // collinear vertices add no waveform detail, but make every
                // subsequent stroke recalculate thousands of redundant joins.
                var renderedY = Double.nan, horizontalX = Double.nan
                for geometry in values where channel < geometry.paths.count {
                    var begins = true
                    let contiguous = previousEnd == geometry.start
                    geometry.paths[channel].forEach { element in
                        let source: CGPoint
                        switch element { case .move(to: let p), .line(to: let p): source = p; default: return }
                        let point = CGPoint(x: Double(geometry.start - origin) / geometry.rate + source.x, y: source.y)
                        // Preserve the existing Canvas vertex precision, while
                        // avoiding a second SwiftUI path build and conversion.
                        // Seam ordering still compares the original coordinates.
                        let rendered = CGPoint(x: CGFloat(Float(point.x)), y: CGFloat(Float(point.y)))
                        if begins && !contiguous {
                            if !horizontalX.isNaN { path.addLine(to: CGPoint(x: horizontalX, y: renderedY)); horizontalX = .nan }
                            path.move(to: rendered); renderedY = rendered.y; lastX = point.x
                        } else if point.x > lastX {
                            if rendered.y == renderedY { horizontalX = rendered.x }
                            else {
                                if !horizontalX.isNaN { path.addLine(to: CGPoint(x: horizontalX, y: renderedY)); horizontalX = .nan }
                                path.addLine(to: rendered); renderedY = rendered.y
                            }
                            lastX = point.x
                        }
                        begins = false
                    }
                    previousEnd = geometry.end
                }
                if !horizontalX.isNaN { path.addLine(to: CGPoint(x: horizontalX, y: renderedY)) }
                return path.copy()!
            }
            paths = cgPaths.map { Path($0) }
        }
    }
    private final class RetainedDrawing: NSObject {
        let drawing: Drawing
        let cost: Int
        init(_ drawing: Drawing) {
            self.drawing = drawing
            // Retain both the source blocks and the flattened display path.
            cost = drawing.values.reduce(0) { $0 + $1.cost } * 2
        }
    }
    private final class DrawingCoverage {
        weak var value: RetainedDrawing?
        let first: Int
        let last: Int
        init(_ value: RetainedDrawing, first: Int, last: Int) {
            self.value = value; self.first = first; self.last = last
        }
    }
    private func coveredDrawing(_ range: ClosedRange<Int>, key: String) -> RetainedDrawing? {
        coverageLock.lock(); defer { coverageLock.unlock() }
        guard let indexed = coverageDrawings[key] else { return nil }
        let live = indexed.filter { $0.value != nil }
        if live.count != indexed.count { coverageDrawings[key] = live.isEmpty ? nil : live }
        // A little retained geometry avoids rejoining every point when zoom
        // changes a source-block boundary. Limit the extra stroke work too:
        // a tiny visible tail must not stroke a whole previously visible item.
        let maximumCount = range.count + max(4, range.count / 2)
        return live.filter { $0.first <= range.lowerBound && $0.last >= range.upperBound && $0.last - $0.first + 1 <= maximumCount }
            .min { $0.last - $0.first < $1.last - $1.first }?.value
    }
    private func indexCoverage(_ value: RetainedDrawing, range: ClosedRange<Int>, key: String) {
        guard !value.drawing.cgPaths.isEmpty else { return }
        coverageLock.lock(); defer { coverageLock.unlock() }
        if coverageDrawings.count >= 256, coverageDrawings[key] == nil { coverageDrawings.removeAll(keepingCapacity: true) }
        var entries = (coverageDrawings[key] ?? []).filter { $0.value != nil }
        if entries.count >= 8 { entries.removeFirst(entries.count - 7) }
        entries.append(DrawingCoverage(value, first: range.lowerBound, last: range.upperBound))
        coverageDrawings[key] = entries
    }
    private func retain(_ drawing: Drawing, key: NSString) -> Drawing {
        guard !drawing.values.isEmpty else { return drawing }
        let value = RetainedDrawing(drawing)
        retained.setObject(value, forKey: key, cost: value.cost)
        return drawing
    }
    func drawing(_ url: URL, header: Header, start: Double, end: Double, pixelsPerSecond: Double) -> Drawing {
        let desired = Self.step(rate: header.rate, pixelsPerSecond: pixelsPerSecond)
        let prefix = header.cachePrefix ?? "\(url.path):\(header.frames)"
        func drawing(_ values: [Geometry], step: Int) -> Drawing {
            let key = "\(prefix):\(step):\(values.map { String($0.start) }.joined(separator: ","))" as NSString
            if let existing = joinedDrawings.object(forKey: key), existing.drawing.values.count == values.count,
               zip(existing.drawing.values, values).allSatisfy({ $0 === $1 }) { return existing.drawing }
            let result = Drawing(values: values, step: step)
            let retained = RetainedDrawing(result)
            joinedDrawings.setObject(retained, forKey: key, cost: retained.cost)
            return result
        }
        func blocks(_ step: Int) -> ClosedRange<Int> {
            let span = Double(Self.span(step: step))
            let first = max(0, Int(floor(start * header.rate / span)))
            return first...max(first, Int(floor(max(start, end - 1 / header.rate) * header.rate / span)))
        }
        let range = blocks(desired)
        // Once a complete source interval is ready, duplicates and successive
        // zoom frames inside the same detail level share it directly. No URL
        // decoding, per-block cache probes, or joined-path validation is needed.
        let completeKey = "complete:\(prefix):\(desired):\(range.lowerBound):\(range.upperBound)" as NSString
        if let complete = joinedDrawings.object(forKey: completeKey) {
            let sourceKey = prefix as NSString
            if retained.object(forKey: sourceKey) !== complete {
                retained.setObject(complete, forKey: sourceKey, cost: complete.cost)
            }
            return complete.drawing
        }
        let coverageKey = "\(prefix):\(desired)"
        if let complete = coveredDrawing(range, key: coverageKey) {
            let sourceKey = prefix as NSString
            if retained.object(forKey: sourceKey) !== complete {
                retained.setObject(complete, forKey: sourceKey, cost: complete.cost)
            }
            return complete.drawing
        }
        let ready = range.compactMap { geometry(url, header: header, block: $0, pixelsPerSecond: pixelsPerSecond) }
        let key = prefix as NSString
        if ready.count == range.count {
            let complete = Drawing(values: ready, step: desired)
            let value = RetainedDrawing(complete)
            joinedDrawings.setObject(value, forKey: completeKey, cost: value.cost)
            indexCoverage(value, range: range, key: coverageKey)
            retained.setObject(value, forKey: key, cost: value.cost)
            return complete
        }
        lock.lock(); let levels = readyLevels[key as String] ?? []; lock.unlock()
        var partial: Drawing?
        for step in levels.sorted(by: { let a = abs(log2(Double($0) / Double(desired))), b = abs(log2(Double($1) / Double(desired))); return a == b ? $0 < $1 : a < b }) where step != desired && step <= desired * 4 {
            // A finer fallback must still have bounded work per visible pixel.
            guard (end - start) * header.rate / Double(step) <= max(1024, (end - start) * pixelsPerSecond * 4) else { continue }
            let span = Self.span(step: step), candidates = blocks(step)
            let values = candidates.compactMap { block -> Geometry? in
                let key = "\(prefix):\(block * span):\(span):\(step)" as NSString
                return geometries.object(forKey: key)
            }
            if values.count == candidates.count { return retain(drawing(values, step: step), key: key) }
            if partial == nil && !values.isEmpty { partial = drawing(values, step: step) }
        }
        if let previous = retained.object(forKey: key)?.drawing {
            let visible = previous.values.filter { Double($0.end) / header.rate > start && Double($0.start) / header.rate < end }
            if !visible.isEmpty {
                if previous.step == desired {
                    var merged = Dictionary(uniqueKeysWithValues: visible.map { ($0.start, $0) })
                    for value in ready { merged[value.start] = value }
                    return retain(drawing(merged.values.sorted { $0.start < $1.start }, step: desired), key: key)
                }
                // Keep the last visible resolution until its replacement covers
                // the viewport, even when only some new blocks have arrived.
                return drawing(visible, step: previous.step)
            }
        }
        if ready.isEmpty, let partial { return retain(partial, key: key) }
        return retain(drawing(ready, step: desired), key: key)
    }

    /// The display thread only looks up immutable curves. Joining their vertices
    /// belongs to the worker, including a warm zoom that exposes another block.
    func displayDrawing(_ url: URL, header: Header, start: Double, end: Double, pixelsPerSecond: Double) -> Drawing {
        let step = Self.step(rate: header.rate, pixelsPerSecond: pixelsPerSecond)
        let prefix = header.cachePrefix ?? "\(url.path):\(header.frames)"
        let span = Double(Self.span(step: step))
        let first = max(0, Int(floor(start * header.rate / span)))
        let last = max(first, Int(floor(max(start, end - 1 / header.rate) * header.rate / span)))
        let key = "complete:\(prefix):\(step):\(first):\(last)" as NSString
        if let ready = joinedDrawings.object(forKey: key) { return ready.drawing }
        if let ready = coveredDrawing(first...last, key: "\(prefix):\(step)") { return ready.drawing }
        enqueue("display:\(key)", url: url, queue: drawingWorker) { [self] in
            // A fallback is not new drawing data. Publishing it would make the
            // Canvas request it again forever while the requested blocks load.
            let wasReady = joinedDrawings.object(forKey: key) != nil
            _ = drawing(url, header: header, start: start, end: end, pixelsPerSecond: pixelsPerSecond)
            return !wasReady && joinedDrawings.object(forKey: key) != nil
        }
        // Never construct a partial replacement on the UI thread. Continue to
        // transform the last ready curve until a complete replacement exists.
        let previous = retained.object(forKey: prefix as NSString)?.drawing
        if let previous, previous.covers(start: start, end: end, rate: header.rate) { return previous }
        if let previous, previous.values.contains(where: { Double($0.end) / header.rate > start && Double($0.start) / header.rate < end }) { return previous }
        return Self.emptyDrawing
    }

    struct DrawingLayer {
        let drawing: Drawing
        let opacity: Double
    }
    fileprivate final class WaveformPresentation: NSObject {
        let layers: [DrawingLayer]
        let start: Double
        let end: Double
        let scale: Double
        let complete: Bool
        init(_ layers: [DrawingLayer], start: Double, end: Double, scale: Double, complete: Bool = true) { self.layers = layers; self.start = start; self.end = end; self.scale = scale; self.complete = complete }
        var cost: Int { layers.reduce(0) { $0 + $1.drawing.values.reduce(0) { $0 + $1.cost } * 2 } }
    }
    private func coveringPresentation(family: String, start: Double, end: Double, rate: Double, preferredStep: Int? = nil) -> WaveformPresentation? {
        presentationIndexLock.lock(); defer { presentationIndexLock.unlock() }
        guard let entries = presentationIndex[family] else { return nil }
        let live = entries.filter { $0.value != nil }
        if live.count != entries.count { presentationIndex[family] = live.isEmpty ? nil : live }
        return live.compactMap(\.value).reversed().first { presentation in
            if let preferredStep, !presentation.layers.allSatisfy({ layer in
                let ratio = Double(layer.drawing.step) / Double(preferredStep)
                return ratio >= 0.25 && ratio <= 4
            }) { return false }
            return presentation.layers.allSatisfy { layer in
                layer.drawing.covers(start: start, end: end, rate: rate)
            }
        }
    }
    private func indexPresentation(_ value: WaveformPresentation, family: String?) {
        guard let family else { return }
        presentationIndexLock.lock(); defer { presentationIndexLock.unlock() }
        if presentationIndex.count >= 512, presentationIndex[family] == nil { presentationIndex.removeAll(keepingCapacity: true) }
        var entries = (presentationIndex[family] ?? []).filter { $0.value != nil }
        if entries.count >= 8 { entries.removeFirst(entries.count - 7) }
        entries.append(WeakPresentation(value))
        presentationIndex[family] = entries
    }
    /// The mounted surface owns its visible curves. NSCache may discard reusable
    /// data at any time, but must never decide what an already visible item draws.
    /// Entries not drawn in the next frame are released; scrolling offscreen
    /// destroys the surface and all of its pins.
    final class PresentationStore {
        private var values: [String: WaveformPresentation] = [:]
        private var used = Set<String>()
        func beginFrame() { used.removeAll(keepingCapacity: true) }
        func endFrame() { values = values.filter { used.contains($0.key) } }
        fileprivate func get(_ key: String) -> WaveformPresentation? {
            used.insert(key)
            return values[key]
        }
        fileprivate func set(_ value: WaveformPresentation, for key: String) {
            used.insert(key)
            values[key] = value
        }
    }
    /// Keep one visible source curve until its replacement covers the interval.
    func drawingLayers(_ url: URL, header: Header, start: Double, end: Double, pixelsPerSecond: Double, presentationID: String? = nil, familyID: String? = nil, owner: PresentationStore? = nil) -> [DrawingLayer] {
        // Independent visible source intervals (including duplicates and tiles)
        // must not replace each other's presentation. Reuse a completed frame
        // before probing lower-level caches that may already have been evicted.
        let interval = presentationID ?? "\(start.bitPattern):\(end.bitPattern)"
        let prefix = header.cachePrefix ?? "\(url.path):\(header.frames)"
        let key = "\(prefix):\(interval)" as NSString
        func keep(_ value: WaveformPresentation) -> [DrawingLayer] {
            owner?.set(value, for: key as String)
            return value.layers
        }
        let pinned = owner?.get(key as String)
        let previousPresentation = pinned ?? presentations.object(forKey: key)
        let family = familyID.map { "\(prefix):\($0)" }
        if let previous = previousPresentation, previous.complete, previous.scale == pixelsPerSecond, previous.start <= start, previous.end >= end - 1 / header.rate { return keep(previous) }
        let level = min(26.0, max(0, log2(max(1, header.rate / max(0.001, pixelsPerSecond) / 2))))
        let fineStep = 1 << Int(floor(level))
        if let previous = previousPresentation,
           previous.layers.allSatisfy({ layer in
               let ratio = Double(layer.drawing.step) / Double(fineStep)
               return ratio >= 0.25 && ratio <= 4 && layer.drawing.covers(start: start, end: end, rate: header.rate)
           }) { return keep(previous) }
        if let family, let previous = coveringPresentation(family: family, start: start, end: end,
                                                            rate: header.rate, preferredStep: fineStep) { return keep(previous) }
        let fineScale = header.rate / Double(fineStep * 2)
        let fine = displayDrawing(url, header: header, start: start, end: end, pixelsPerSecond: fineScale)
        let complete = fine.step == fineStep && fine.covers(start: start, end: end, rate: header.rate)
        if complete {
            let layers = [DrawingLayer(drawing: fine, opacity: 1)]
            let presentation = WaveformPresentation(layers, start: start, end: end, scale: pixelsPerSecond)
            presentations.setObject(presentation, forKey: key, cost: presentation.cost)
            indexPresentation(presentation, family: family)
            return keep(presentation)
        }
        if let family, let previous = coveringPresentation(family: family, start: start, end: end, rate: header.rate) { return keep(previous) }
        if let previous = previousPresentation, previous.layers.allSatisfy({ layer in
            layer.drawing.covers(start: start, end: end, rate: header.rate)
        }) { return keep(previous) }
        if fine.values.isEmpty, let previous = previousPresentation,
           previous.layers.contains(where: { $0.drawing.values.contains { Double($0.start) / header.rate < end && Double($0.end) / header.rate > start } }) {
            return keep(previous)
        }
        let fallback = fine
        let layers = [DrawingLayer(drawing: fallback, opacity: 1)]
        if !fallback.values.isEmpty {
            let presentation = WaveformPresentation(layers, start: start, end: end, scale: pixelsPerSecond, complete: false)
            presentations.setObject(presentation, forKey: key, cost: presentation.cost)
            indexPresentation(presentation, family: family)
            return keep(presentation)
        }
        return layers
    }

    private func registerLevel(_ key: String, step: Int) {
        lock.lock()
        if readyLevels.count >= 512, readyLevels[key] == nil { readyLevels.removeAll(keepingCapacity: true) }
        readyLevels[key, default: []].insert(step)
        lock.unlock()
    }

    /// Peak-cache analysis runs on a utility worker. Read tiny PCM windows only
    /// around rising click peaks to recover their exact original sample onset.
    static func clickOnsets(_ url: URL) throws -> [Double] {
        try clickTransients(url).map(\.position)
    }
    static func clickTransients(_ url: URL) throws -> [(position: Double, peak: Double, shape: [Double])] {
        let file = try AVAudioFile(forReading: url)
        let header = Header(rate: file.processingFormat.sampleRate, frames: file.length, channels: Int(file.processingFormat.channelCount))
        let source = try WaveformSource.loadOrBuild(url, header: header)
        let peaks = source.peakLevels()
        let maximum = peaks.max() ?? 0
        guard maximum > 0.00001 else { return [] }
        let threshold = maximum * 0.04
        let silence = maximum * 0.001
        var result: [(position: Double, peak: Double, shape: [Double])] = []
        var armed = true, previous = -Double.infinity
        let capacity = WaveformSource.baseStep * 2
        let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(capacity))!
        for (index, peak) in peaks.enumerated() {
            if index % 4096 == 0 { try Task.checkCancellation() }
            if peak < threshold * 0.3 { armed = true }
            guard armed, peak >= threshold else { continue }
            armed = false
            let first = max(0, (index - 1) * WaveformSource.baseStep)
            guard Double(first) / header.rate - previous >= 0.08 else { continue }
            file.framePosition = Int64(first)
            try file.read(into: pcm, frameCount: AVAudioFrameCount(min(capacity, Int(file.length) - first)))
            guard let channels = pcm.floatChannelData else { continue }
            var onset: Int?
            for sample in 0..<Int(pcm.frameLength) {
                if (0..<header.channels).contains(where: { abs(channels[$0][sample * pcm.stride]) >= silence }) { onset = first + sample; break }
            }
            if let onset {
                previous = Double(onset) / header.rate
                let frames = min(Int(file.length) - onset, Int(header.rate * 0.03))
                guard frames > 0, let detail = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)) else { continue }
                file.framePosition = Int64(onset)
                try file.read(into: detail, frameCount: AVAudioFrameCount(frames))
                guard let samples = detail.floatChannelData, detail.frameLength > 0 else { continue }
                let count = Int(detail.frameLength)
                var strongestPeak = 0.0, shape: [Double] = []
                for channel in 0..<header.channels {
                    var peak = 0.0, energy = 0.0, earlyEnergy = 0.0, crossings = 0
                    var previousSample = 0.0
                    for frame in 0..<count {
                        let value = Double(samples[channel][frame * detail.stride])
                        peak = max(peak, abs(value)); energy += value * value
                        if frame < count / 3 { earlyEnergy += value * value }
                        if value * previousSample < 0 { crossings += 1 }
                        previousSample = value
                    }
                    if peak > strongestPeak {
                        strongestPeak = peak
                        shape = [Double(crossings) / Double(count) * header.rate / 4000,
                                 sqrt(energy / Double(count)) / max(peak, 0.000001),
                                 earlyEnergy / max(energy, 0.000000001)]
                    }
                }
                result.append((previous, strongestPeak, shape))
            }
        }
        return result
    }
    static func step(rate: Double, pixelsPerSecond: Double) -> Int {
        // Keep simplification below half a point, including Retina displays.
        // This also retains every sample at close zoom with the same stroke.
        let framesPerPixel = max(1, rate / max(0.001, pixelsPerSecond) / 2)
        return 1 << min(26, max(0, Int(floor(log2(framesPerPixel)))))
    }
    static func span(step: Int) -> Int { max(512, step * 128) }

    /// Versions let a prepared file invalidate only the surfaces containing it.
    func version(_ url: URL) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return fileVersions[url.path] ?? 0
    }

    private func prepareSource(_ url: URL, header: Header) {
        let sourceKey = (header.cachePrefix ?? "\(url.path):\(header.frames)") as NSString
        enqueue("source:\(sourceKey)", url: url, queue: sourceWorker) { [self] in
            do {
                let source = try WaveformSource.loadOrBuild(url, header: header)
                _ = prepareZoomOutVertices(source, header: header, prefix: sourceKey as String)
                sources.setObject(source, forKey: sourceKey, cost: source.cost)
                return true
            } catch { return false }
        }
    }

    private func file(_ url: URL) throws -> AVAudioFile {
        if let existing = files[url.path] { return existing }
        let audio = try AVAudioFile(forReading: url)
        if files.count >= 8 { files.removeAll(keepingCapacity: true) }
        files[url.path] = audio
        return audio
    }

    private func enqueue(_ key: String, url: URL, queue: DispatchQueue? = nil, work: @escaping () -> Bool) {
        lock.lock()
        guard pending.count < 64, pending.insert(key).inserted else { lock.unlock(); return }
        lock.unlock()
        (queue ?? worker).async { [self] in
            let changed = autoreleasepool { work() }
            lock.lock()
            pending.remove(key)
            if changed { fileVersions[url.path, default: 0] &+= 1 }
            lock.unlock()
            guard changed else { return }
            DispatchQueue.main.async { [self] in
                guard !notificationPending else { return }
                notificationPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [self] in
                    notificationPending = false
                    revision &+= 1
                }
            }
        }
    }
}

/// REAPER-style signed minimum/maximum pairs: four bytes per interval/channel.
/// The binary directory indexes sparse mip levels. Read-only mapped pages can
/// be reclaimed by macOS; opening a project does not copy every source to RAM.
private final class WaveformSource: NSObject {
    static let baseStep = 256
    private static let recordBytes = 4
    private static let magic = Array("JARASPK4".utf8)
    private struct Stored: Decodable {
        let version: Int
        let size: Int64
        let modified: TimeInterval
        let rate: Double
        let frames: Int64
        let channels: Int
        let samples: Data
    }
    private struct Level {
        let step: Int
        let samples: Data
    }
    private final class Mapping {
        let pointer: UnsafeMutableRawPointer
        let count: Int
        init?(_ url: URL) {
            let descriptor = Darwin.open(url.path, O_RDONLY)
            guard descriptor >= 0 else { return nil }
            defer { Darwin.close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_size >= 48,
                  info.st_size <= Int.max else { return nil }
            count = Int(info.st_size)
            guard let address = mmap(nil, count, PROT_READ, MAP_PRIVATE, descriptor, 0),
                  address != MAP_FAILED else { return nil }
            pointer = address
            // Viewing one song must not read ahead through an entire project.
            madvise(pointer, count, MADV_RANDOM)
        }
        deinit { munmap(pointer, count) }
        func data(offset: Int, count: Int) -> Data {
            Data(bytesNoCopy: pointer.advanced(by: offset), count: count, deallocator: .none)
        }
    }
    let samples: Data
    private let levels: [Level]
    private let mapping: Mapping?
    var cost: Int { samples.count + levels.reduce(0) { $0 + $1.samples.count } }
    var mappedByteCount: Int { mapping?.count ?? 0 }
    var ownedByteCount: Int { mapping == nil ? cost : 0 }
    let rate: Double
    let frames: Int64
    let channels: Int

    private init(samples: Data, rate: Double, frames: Int64, channels: Int,
                 levels: [Level]? = nil, mapping: Mapping? = nil) {
        self.samples = samples; self.rate = rate; self.frames = frames; self.channels = channels
        self.levels = levels ?? Self.pyramid(samples: samples, frames: frames, channels: channels)
        self.mapping = mapping
    }
    private static func pyramid(samples: Data, frames: Int64, channels: Int) -> [Level] {
        var result: [Level] = []
        var input = samples, sourceStep = baseStep
        var count = Int((frames + Int64(baseStep) - 1) / Int64(baseStep))
        while count > 1 && sourceStep < 1 << 26 {
            let nextStep = sourceStep * 4, nextCount = (count + 3) / 4
            var output = Data(count: nextCount * channels * recordBytes)
            input.withUnsafeBytes { raw in
                output.withUnsafeMutableBytes { out in
                    for bucket in 0..<nextCount {
                        for channel in 0..<channels {
                            var high = Int16.min, low = Int16.max
                            for source in (bucket * 4)..<min(count, bucket * 4 + 4) {
                                let offset = (source * channels + channel) * recordBytes
                                high = max(high, Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self)))
                                low = min(low, Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 2, as: Int16.self)))
                            }
                            let offset = (bucket * channels + channel) * recordBytes
                            out.storeBytes(of: high.littleEndian, toByteOffset: offset, as: Int16.self)
                            out.storeBytes(of: low.littleEndian, toByteOffset: offset + 2, as: Int16.self)
                        }
                    }
                }
            }
            result.append(Level(step: nextStep, samples: output))
            input = output; sourceStep = nextStep; count = nextCount
        }
        return result
    }
    private func persist(to destination: URL, size: Int64, modified: TimeInterval) {
        let entries = [Level(step: Self.baseStep, samples: samples)] + levels
        var encoded = Data(Self.magic)
        func append<T>(_ value: T) { var value = value; withUnsafeBytes(of: &value) { encoded.append(contentsOf: $0) } }
        append(size.littleEndian); append(modified.bitPattern.littleEndian)
        append(rate.bitPattern.littleEndian); append(frames.littleEndian)
        append(UInt32(channels).littleEndian); append(UInt32(entries.count).littleEndian)
        var offset = 48 + entries.count * 24
        for entry in entries {
            append(UInt64(entry.step).littleEndian); append(UInt64(offset).littleEndian)
            append(UInt64(entry.samples.count).littleEndian); offset += entry.samples.count
        }
        for entry in entries { encoded.append(entry.samples) }
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoded.write(to: destination, options: .atomic)
    }
    private static func mapped(_ destination: URL, header: TimelineAudioWaveform.Header,
                               size: Int64, modified: TimeInterval) -> WaveformSource? {
        guard let mapping = Mapping(destination) else { return nil }
        let raw = UnsafeRawBufferPointer(start: mapping.pointer, count: mapping.count)
        func u64(_ offset: Int) -> UInt64 { UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
        func u32(_ offset: Int) -> UInt32 { UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        guard Array(raw.prefix(8)) == magic, u64(8) == UInt64(bitPattern: size),
              u64(16) == modified.bitPattern, u64(24) == header.rate.bitPattern,
              u64(32) == UInt64(bitPattern: header.frames),
              u32(40) == header.channels + (header.channels > 1 ? 1 : 0) else { return nil }
        let count = Int(u32(44)), channels = Int(u32(40))
        guard count > 0, count <= 16, channels > 0, channels <= 256,
              48 + count * 24 <= mapping.count else { return nil }
        var entries: [Level] = [], expectedOffset = 48 + count * 24, expectedStep = baseStep
        for index in 0..<count {
            let position = 48 + index * 24
            let step = u64(position), offset = u64(position + 8), length = u64(position + 16)
            let buckets = (header.frames + Int64(expectedStep) - 1) / Int64(expectedStep)
            guard step == UInt64(expectedStep), offset == UInt64(expectedOffset),
                  buckets <= Int.max / (channels * recordBytes),
                  length == UInt64(buckets) * UInt64(channels * recordBytes),
                  length <= UInt64(mapping.count - expectedOffset) else { return nil }
            entries.append(Level(step: expectedStep, samples: mapping.data(offset: expectedOffset, count: Int(length))))
            expectedOffset += Int(length); expectedStep *= 4
        }
        guard expectedOffset == mapping.count, let first = entries.first,
              entries.last!.step >= 1 << 26 || header.frames <= Int64(entries.last!.step) else { return nil }
        return WaveformSource(samples: first.samples, rate: header.rate, frames: header.frames,
            channels: channels, levels: Array(entries.dropFirst()), mapping: mapping)
    }
    static func cacheURL(_ url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        var ancestor = directory
        while ancestor.path != "/" {
            if ["steams", "stems"].contains(ancestor.lastPathComponent.lowercased()) {
                let relative = String(url.path.dropFirst(ancestor.path.count + 1))
                return ancestor.deletingLastPathComponent().appendingPathComponent("WF", isDirectory: true)
                    .appendingPathComponent(relative + ".waveform")
            }
            ancestor.deleteLastPathComponent()
        }
        return directory.appendingPathComponent("WF", isDirectory: true).appendingPathComponent(url.lastPathComponent + ".waveform")
    }
    static func loadOrBuild(_ url: URL, header: TimelineAudioWaveform.Header) throws -> WaveformSource {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let destination = cacheURL(url)
        if let cached = mapped(destination, header: header, size: size, modified: modified) { return cached }
        let count = Int((header.frames + Int64(baseStep) - 1) / Int64(baseStep))
        let storedChannels = header.channels + (header.channels > 1 ? 1 : 0)
        let expectedBytes = count * storedChannels * recordBytes
        // Read old peak caches once; migration never decodes their audio again.
        // Ignoring old coarser levels also avoids allocating their duplicate data.
        if let data = try? Data(contentsOf: destination, options: .mappedIfSafe),
           let saved = try? PropertyListDecoder().decode(Stored.self, from: data),
           (saved.version == 2 || saved.version == 3), saved.size == size, saved.modified == modified,
           saved.frames == header.frames, saved.rate == header.rate, saved.channels == storedChannels,
           saved.samples.count == count * storedChannels * 20 {
            var packed = Data(count: expectedBytes)
            saved.samples.withUnsafeBytes { input in
                packed.withUnsafeMutableBytes { output in
                    for index in 0..<(count * storedChannels) {
                        let low = Float(bitPattern: UInt32(littleEndian: input.loadUnaligned(fromByteOffset: index * 20 + 8, as: UInt32.self)))
                        let high = Float(bitPattern: UInt32(littleEndian: input.loadUnaligned(fromByteOffset: index * 20 + 12, as: UInt32.self)))
                        output.storeBytes(of: WaveformPeakCodec.encode(high).littleEndian, toByteOffset: index * 4, as: Int16.self)
                        output.storeBytes(of: WaveformPeakCodec.encode(low).littleEndian, toByteOffset: index * 4 + 2, as: Int16.self)
                    }
                }
            }
            let source = WaveformSource(samples: packed, rate: saved.rate, frames: saved.frames, channels: saved.channels)
            source.persist(to: destination, size: size, modified: modified)
            return mapped(destination, header: header, size: size, modified: modified) ?? source
        }
        let audio = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(TimelineAudioWaveform.blockFrames)) else {
            throw NSError(domain: "JarasWaveform", code: 1)
        }
        var data = Data(capacity: expectedBytes)
        func append(_ value: Float) { var packed = WaveformPeakCodec.encode(value).littleEndian; withUnsafeBytes(of: &packed) { data.append(contentsOf: $0) } }
        while data.count < expectedBytes {
            try audio.read(into: buffer, frameCount: AVAudioFrameCount(TimelineAudioWaveform.blockFrames))
            guard let pointers = buffer.floatChannelData, buffer.frameLength > 0 else { break }
            for offset in stride(from: 0, to: Int(buffer.frameLength), by: baseStep) {
                let length = min(baseStep, Int(buffer.frameLength) - offset)
                for channel in 0..<header.channels {
                    let pointer = pointers[channel].advanced(by: offset * buffer.stride)
                    var minimum: Float = 0, maximum: Float = 0
                    vDSP_minv(pointer, vDSP_Stride(buffer.stride), &minimum, vDSP_Length(length))
                    vDSP_maxv(pointer, vDSP_Stride(buffer.stride), &maximum, vDSP_Length(length))
                    append(maximum); append(minimum)
                }
                // Mono peaks must come from the signed audio mix. Summing peak
                // magnitudes would lose cancellation between opposite channels.
                if header.channels > 1 {
                    func mixed(_ index: Int) -> Float { (pointers[0][(offset + index) * buffer.stride] + pointers[1][(offset + index) * buffer.stride]) * 0.5 }
                    var minimum = mixed(0), maximum = minimum
                    for index in 1..<length {
                        let sample = mixed(index); minimum = min(minimum, sample); maximum = max(maximum, sample)
                    }
                    append(maximum); append(minimum)
                }
            }
        }
        guard data.count == expectedBytes else { throw NSError(domain: "JarasWaveform", code: 2) }
        let source = WaveformSource(samples: data, rate: header.rate, frames: header.frames, channels: storedChannels)
        if let current = try? FileManager.default.attributesOfItem(atPath: url.path),
           (current[.size] as? NSNumber)?.int64Value == size,
           (current[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate == modified {
            source.persist(to: destination, size: size, modified: modified)
            return mapped(destination, header: header, size: size, modified: modified) ?? source
        }
        return source
    }
    func peakLevels() -> [Float] {
        let count = samples.count / (channels * Self.recordBytes)
        return samples.withUnsafeBytes { raw in
            (0..<count).map { index in
                var peak: Float = 0
                for channel in 0..<channels {
                    let offset = (index * channels + channel) * Self.recordBytes
                    for field in [0, 2] {
                        let value = WaveformPeakCodec.decode(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset + field, as: Int16.self)))
                        peak = max(peak, abs(value))
                    }
                }
                return peak
            }
        }
    }
    /// Materialize only one visible block. At most two intervals of an indexed
    /// level are merged for a power-of-two request; work is bounded by pixels.
    func vertices(start: Int64, step: Int, span: Int, key: String) -> TimelineAudioWaveform.VertexBlock {
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
    func geometry(start: Int64, step: Int, span: Int) -> TimelineAudioWaveform.Geometry {
        let block = vertices(start: start, step: step, span: span, key: "")
        return TimelineAudioWaveform.Geometry(vertices: block)
    }
}
