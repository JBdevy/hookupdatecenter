import SwiftUI
import AVFoundation
import Accelerate

/// Read only visible audio blocks, independently of the playback engine.
/// Immutable PCM and drawing paths are shared by duplicates and zoom levels.
final class TimelineAudioWaveform: ObservableObject {
    static let shared = TimelineAudioWaveform()
    static let blockFrames = 65_536
    @Published private(set) var revision: UInt64 = 0

    final class Header: NSObject {
        let rate: Double
        let frames: Int64
        let channels: Int
        let sourcePath: String?
        let cachePrefix: String?
        let checkedAt = ProcessInfo.processInfo.systemUptime
        init(rate: Double, frames: Int64, channels: Int = 1, sourcePath: String? = nil) {
            self.rate = rate; self.frames = frames; self.channels = channels
            self.sourcePath = sourcePath
            cachePrefix = sourcePath.map { "\($0):\(frames)" }
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
        init(buckets: [[Bucket]], start: Int64, rate: Double, frames: Int64, span: Int, step: Int) {
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

    private let headers = NSCache<NSString, Header>()
    private let pcm = NSCache<NSString, PCM>()
    private let geometries = NSCache<NSString, Geometry>()
    private let joinedDrawings = NSCache<NSString, RetainedDrawing>()
    // Weak entries point into the existing byte-bounded drawing caches. They
    // never retain an extra waveform merely because the viewport once used it.
    private let coverageLock = NSLock()
    private var coverageDrawings: [String: [DrawingCoverage]] = [:]
    private let sources = NSCache<NSString, WaveformSource>()
    private let sourceWorker = DispatchQueue(label: "jaras.waveform.prepare", qos: .utility)
    private var fileVersions: [String: UInt64] = [:]
    private let worker: DispatchQueue
    private let retained = NSCache<NSString, RetainedDrawing>()
    private let lock = NSLock()
    private var pending = Set<String>()
    private var notificationPending = false
    private var readyLevels: [String: Set<Int>] = [:]
    private var files: [String: AVAudioFile] = [:] // Accessed only by worker.

    init(worker: DispatchQueue = DispatchQueue(label: "jaras.waveform.decode", qos: .utility)) {
        self.worker = worker
        sources.totalCostLimit = 48 * 1024 * 1024
        headers.countLimit = 512
        pcm.totalCostLimit = 48 * 1024 * 1024
        geometries.totalCostLimit = 24 * 1024 * 1024
        // Bound bytes, not tile count: a wide viewport can need more than 512
        // small tiles, and evicting those while still visible causes reloads.
        retained.totalCostLimit = 16 * 1024 * 1024
        retained.countLimit = 128
        joinedDrawings.totalCostLimit = 16 * 1024 * 1024
        joinedDrawings.countLimit = 128
    }

    func header(_ url: URL, refresh: Bool = false) -> Header? {
        let key = url.path as NSString
        let previous = headers.object(forKey: key)
        if let value = previous, !refresh || ProcessInfo.processInfo.systemUptime - value.checkedAt < 1 {
            return value.rate > 0 ? value : nil
        }
        enqueue("header:\(url.path)", url: url) { [self] in
            if refresh { files.removeValue(forKey: url.path) }
            if let audio = try? file(url) {
                headers.setObject(Header(rate: audio.processingFormat.sampleRate, frames: audio.length, channels: Int(audio.processingFormat.channelCount), sourcePath: key as String), forKey: key)
                return previous?.frames != audio.length || previous?.rate != audio.processingFormat.sampleRate || previous?.channels != Int(audio.processingFormat.channelCount)
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
                registerLevel(url, frames: header.frames, step: step)
                return true
            }
            guard let audio = try? file(url) else { return false }
            let data: PCM
            if let cached = pcm.object(forKey: rawKey as NSString) { data = cached }
            else {
                let count = AVAudioFrameCount(min(Int64(span + 512), header.frames - start))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: count) else { return false }
                do {
                    audio.framePosition = start
                    try audio.read(into: buffer, frameCount: count)
                } catch { return false }
                guard let pointers = buffer.floatChannelData, buffer.frameLength > 0 else { return false }
                let frames = Int(buffer.frameLength), stride = buffer.stride
                data = PCM(channels: (0..<Int(buffer.format.channelCount)).map { channel in
                    (0..<frames).map { pointers[channel][$0 * stride] }
                })
                pcm.setObject(data, forKey: rawKey as NSString, cost: frames * data.channels.count * 4)
            }
            let value = Geometry(pcm: data, start: start, rate: header.rate, step: step, span: span)
            geometries.setObject(value, forKey: key, cost: value.cost)
            registerLevel(url, frames: header.frames, step: step)
            return true
        }
        return nil
    }

    struct Drawing {
        let values: [Geometry]
        let step: Int
        let origin: Int64
        let paths: [Path]
        let cgPaths: [CGPath]
        init(values: [Geometry], step: Int) {
            self.values = values; self.step = step
            origin = values.first?.start ?? 0
            let origin = origin
            cgPaths = (0..<(values.first?.paths.count ?? 0)).map { channel in
                let path = CGMutablePath()
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
        for step in levels.sorted(by: { let a = abs(log2(Double($0) / Double(desired))), b = abs(log2(Double($1) / Double(desired))); return a == b ? $0 < $1 : a < b }) where step != desired {
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

    private func registerLevel(_ url: URL, frames: Int64, step: Int) {
        let key = "\(url.path):\(frames)"
        lock.lock()
        if readyLevels.count >= 512, readyLevels[key] == nil { readyLevels.removeAll(keepingCapacity: true) }
        readyLevels[key, default: []].insert(step)
        lock.unlock()
    }

    /// Peak-cache analysis runs on a utility worker. Read tiny PCM windows only
    /// around rising click peaks to recover their exact original sample onset.
    static func clickOnsets(_ url: URL) throws -> [Double] {
        let file = try AVAudioFile(forReading: url)
        let header = Header(rate: file.processingFormat.sampleRate, frames: file.length, channels: Int(file.processingFormat.channelCount))
        let source = try WaveformSource.loadOrBuild(url, header: header)
        let peaks = source.peakLevels()
        let maximum = peaks.max() ?? 0
        guard maximum > 0.00001 else { return [] }
        let threshold = maximum * 0.15
        let silence = maximum * 0.001
        var result: [Double] = [], armed = true, previous = -Double.infinity
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
            if let onset { previous = Double(onset) / header.rate; result.append(previous) }
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
                sources.setObject(source, forKey: sourceKey, cost: source.samples.count)
                // A full-file curve remains available even when a large zoom
                // exposes audio that no previous viewport had requested.
                let step = max(512, 1 << min(26, Int(ceil(log2(max(1, Double(header.frames) / 128))))))
                let span = Self.span(step: step)
                let overview = source.geometry(start: 0, step: step, span: span)
                let key = "\(url.path):\(header.frames):0:\(span):\(step)" as NSString
                geometries.setObject(overview, forKey: key, cost: overview.cost)
                registerLevel(url, frames: header.frames, step: step)
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

/// Persist signed sample landmarks, including their exact source positions.
/// This is drawing data only; playback always reads the original audio file.
private final class WaveformSource: NSObject {
    static let baseStep = 256
    private static let recordBytes = 20
    private struct Stored: Codable {
        let version: Int
        let size: Int64
        let modified: TimeInterval
        let rate: Double
        let frames: Int64
        let channels: Int
        let samples: Data
    }
    let samples: Data
    let rate: Double
    let frames: Int64
    let channels: Int
    init(samples: Data, rate: Double, frames: Int64, channels: Int) {
        self.samples = samples; self.rate = rate; self.frames = frames; self.channels = channels
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
        let count = Int((header.frames + Int64(baseStep) - 1) / Int64(baseStep))
        let storedChannels = header.channels + (header.channels > 1 ? 1 : 0)
        let expectedBytes = count * storedChannels * recordBytes
        if let data = try? Data(contentsOf: destination),
           let saved = try? PropertyListDecoder().decode(Stored.self, from: data),
           saved.version == 2, saved.size == size, saved.modified == modified,
           saved.frames == header.frames, saved.rate == header.rate, saved.channels == storedChannels,
           saved.samples.count == expectedBytes {
            return WaveformSource(samples: saved.samples, rate: saved.rate, frames: saved.frames, channels: saved.channels)
        }
        let audio = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(TimelineAudioWaveform.blockFrames)) else {
            throw NSError(domain: "JarasWaveform", code: 1)
        }
        var data = Data(capacity: expectedBytes)
        func append<T>(_ value: T) { var value = value; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        while data.count < expectedBytes {
            try audio.read(into: buffer, frameCount: AVAudioFrameCount(TimelineAudioWaveform.blockFrames))
            guard let pointers = buffer.floatChannelData, buffer.frameLength > 0 else { break }
            for offset in stride(from: 0, to: Int(buffer.frameLength), by: baseStep) {
                let length = min(baseStep, Int(buffer.frameLength) - offset)
                for channel in 0..<header.channels {
                    let pointer = pointers[channel].advanced(by: offset * buffer.stride)
                    var minimum: Float = 0, maximum: Float = 0
                    var low: vDSP_Length = 0, high: vDSP_Length = 0
                    vDSP_minvi(pointer, vDSP_Stride(buffer.stride), &minimum, &low, vDSP_Length(length))
                    vDSP_maxvi(pointer, vDSP_Stride(buffer.stride), &maximum, &high, vDSP_Length(length))
                    append(pointer[0].bitPattern.littleEndian)
                    append(pointer[(length - 1) * buffer.stride].bitPattern.littleEndian)
                    append(minimum.bitPattern.littleEndian); append(maximum.bitPattern.littleEndian)
                    append(UInt16(Int(low) / buffer.stride).littleEndian)
                    append(UInt16(Int(high) / buffer.stride).littleEndian)
                }
                if header.channels > 1 {
                    var low = 0, high = 0
                    func mixed(_ index: Int) -> Float { (pointers[0][(offset + index) * buffer.stride] + pointers[1][(offset + index) * buffer.stride]) * 0.5 }
                    var minimum = mixed(0), maximum = minimum
                    for index in 1..<length {
                        let sample = mixed(index)
                        if sample < minimum { minimum = sample; low = index }
                        if sample > maximum { maximum = sample; high = index }
                    }
                    append(mixed(0).bitPattern.littleEndian); append(mixed(length - 1).bitPattern.littleEndian)
                    append(minimum.bitPattern.littleEndian); append(maximum.bitPattern.littleEndian)
                    append(UInt16(low).littleEndian); append(UInt16(high).littleEndian)
                }
            }
        }
        guard data.count == expectedBytes else { throw NSError(domain: "JarasWaveform", code: 2) }
        let source = WaveformSource(samples: data, rate: header.rate, frames: header.frames, channels: storedChannels)
        // A failed cache write never prevents drawing or opening the project.
        // Never publish a cache for a recording that changed while being read.
        if let current = try? FileManager.default.attributesOfItem(atPath: url.path),
           (current[.size] as? NSNumber)?.int64Value == size,
           (current[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate == modified {
            let saved = Stored(version: 2, size: size, modified: modified, rate: header.rate, frames: header.frames, channels: storedChannels, samples: data)
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            if let encoded = try? encoder.encode(saved) {
                try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? encoded.write(to: destination, options: .atomic)
            }
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
                    for field in [8, 12] {
                        let value = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + field, as: UInt32.self)))
                        peak = max(peak, abs(value))
                    }
                }
                return peak
            }
        }
    }
    func geometry(start: Int64, step: Int, span: Int) -> TimelineAudioWaveform.Geometry {
        let remaining = max(0, min(Int64(span + 1), frames - start))
        let count = Int((remaining + Int64(step) - 1) / Int64(step))
        var buckets = Array(repeating: Array(repeating: TimelineAudioWaveform.Bucket(), count: count), count: channels)
        samples.withUnsafeBytes { raw in
            func float(_ offset: Int) -> Float { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) }
            let first = Int(start) / Self.baseStep
            let last = Int((start + remaining + Int64(Self.baseStep) - 1) / Int64(Self.baseStep))
            for index in first..<last {
                let frame = index * Self.baseStep
                let local = frame - Int(start), bucket = local / step
                guard bucket >= 0, bucket < count else { continue }
                for channel in 0..<channels {
                    let offset = (index * channels + channel) * Self.recordBytes
                    guard offset + Self.recordBytes <= raw.count else { continue }
                    let low = Int(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 16, as: UInt16.self)))
                    let high = Int(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 18, as: UInt16.self)))
                    if local + Self.baseStep > Int(remaining), start + remaining < frames {
                        let sample = TimelineAudioWaveform.Sample(frame: local, value: float(offset))
                        buckets[channel][bucket].include(first: sample, last: sample, minimum: sample, maximum: sample)
                        continue
                    }
                    buckets[channel][bucket].include(
                        first: .init(frame: local, value: float(offset)),
                        last: .init(frame: min(Int(frames) - 1, frame + Self.baseStep - 1) - Int(start), value: float(offset + 4)),
                        minimum: .init(frame: local + low, value: float(offset + 8)),
                        maximum: .init(frame: local + high, value: float(offset + 12)))
                }
            }
        }
        return TimelineAudioWaveform.Geometry(buckets: buckets, start: start, rate: rate, frames: remaining, span: span, step: step)
    }
}
