import Foundation
import AVFoundation
import SwiftUI
import CryptoKit
import Accelerate

/// A folder is a visual sum, never another playable item. Fixed time pages are
/// mixed off the UI/audio threads and retained across scrolling and zoom.
final class FolderWaveformCache: ObservableObject {
    static let shared = FolderWaveformCache()
    static let rate = 44_100.0
    static let pageSeconds = 16.0
    static let step = 256
    struct Source: Hashable, Codable {
        let url: URL
        let start: Double, duration: Double, offset: Double, rate: Double
        let loopStart: Double?, loopLength: Double?
        let gain: Double, pan: Double
        let fadeIn: Double, fadeOut: Double, fadeStart: Double, fadeDuration: Double
        let mode: Int
    }
    struct Request: Hashable {
        let folder: UUID
        let sources: [Source]
        let page: Int
    }
    struct PreparedPage {
        let request: Request
        let key: String
        let activeRanges: [ClosedRange<Double>]
    }
    struct PresentedPage {
        let page: Int
        let block: TimelineAudioWaveform.VertexBlock
        let activeRanges: [ClosedRange<Double>]
    }
    /// A visible folder keeps its last coherent set independently of cache
    /// eviction and of partially completed replacements for a newer gain edit.
    final class Presentation {
        fileprivate var folder: UUID?
        fileprivate var displayed: [Int: Entry] = [:]
        fileprivate var replacements: [String: Entry] = [:]
    }
    static func prepare(folder: UUID, sources: [Source], page: Int) -> PreparedPage {
        let start = Double(page) * pageSeconds, end = start + pageSeconds
        let relevant = sources.filter { $0.gain != 0 && $0.duration > 0 && $0.rate > 0 && $0.start < end && $0.start + $0.duration > start }
        let request = Request(folder: folder, sources: relevant, page: page)
        let intervals = relevant.map { max(start, $0.start)...min(end, $0.start + $0.duration) }.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for interval in intervals {
            if let previous = merged.last, interval.lowerBound <= previous.upperBound {
                merged[merged.count - 1] = previous.lowerBound...max(previous.upperBound, interval.upperBound)
            } else { merged.append(interval) }
        }
        return PreparedPage(request: request, key: "folder:\(request.hashValue)", activeRanges: merged)
    }
    @Published private(set) var revision = 0
    fileprivate final class Entry: NSObject {
        struct Level { let step: Int, count: Int, offset: Int }
        let data: Data
        let levels: [Level]
        let start: Int64
        let key: String
        let activeRanges: [ClosedRange<Double>]
        var cost: Int { data.count }
        // Indexed little-endian binary cache. Each peak is a signed Int16
        // max/min pair, using the REAPER RPKL amplitude encoding. Positions
        // are implicit in the bucket index; GPU vertices are visible-only.
        init?(data: Data, start: Int64, key: String, fingerprint: String, activeRanges: [ClosedRange<Double>]) {
            guard data.count >= 76, data.prefix(4) == Data("JFS2".utf8),
                  String(data: data.subdata(in: 4..<68), encoding: .utf8) == fingerprint else { return nil }
            var levels: [Level] = []
            let valid = data.withUnsafeBytes { raw -> Bool in
                func integer(_ offset: Int) -> Int { Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))) }
                guard integer(68) == 3 else { return false }
                let count = integer(72)
                guard (1...16).contains(count), data.count >= 76 + count * 12 else { return false }
                var expectedStep = FolderWaveformCache.step, expectedOffset = 76 + count * 12
                for index in 0..<count {
                    let header = 76 + index * 12
                    let step = integer(header), buckets = integer(header + 4), offset = integer(header + 8)
                    let expectedCount = (Int(pageSeconds * rate) + step - 1) / max(1, step)
                    guard step == expectedStep, buckets == expectedCount, offset == expectedOffset,
                          offset <= data.count, buckets <= (data.count - offset) / 12 else { return false }
                    levels.append(Level(step: step, count: buckets, offset: offset))
                    expectedOffset += buckets * 12; expectedStep *= 4
                }
                return expectedOffset == data.count && levels.last!.count == 1
            }
            guard valid else { return nil }
            self.data = data; self.levels = levels; self.start = start; self.key = key
            self.activeRanges = activeRanges
        }
        static func encoded(_ base: TimelineAudioWaveform.VertexBlock, fingerprint: String) -> Data {
            let frames = Int(pageSeconds * rate)
            let count = (frames + FolderWaveformCache.step - 1) / FolderWaveformCache.step
            var values = [SIMD2<Float>](repeating: SIMD2(-Float.infinity, Float.infinity), count: count * 3)
            var lastValues = [Float](repeating: .nan, count: count * 3)
            for channel in 0..<min(3, base.channels.count) {
                for point in base.channels[channel] {
                    let bucket = min(count - 1, max(0, Int(point.x) / FolderWaveformCache.step)), value = -point.y
                    values[bucket * 3 + channel].x = max(values[bucket * 3 + channel].x, value)
                    values[bucket * 3 + channel].y = min(values[bucket * 3 + channel].y, value)
                    lastValues[bucket * 3 + channel] = value
                }
                // VertexBlock collapses long constant runs. Recover their
                // envelope without inventing energy between distant items.
                var previous: Float = 0
                for bucket in 0..<count {
                    if values[bucket * 3 + channel].x.isFinite {
                        previous = lastValues[bucket * 3 + channel]
                    } else { values[bucket * 3 + channel] = SIMD2(repeating: previous) }
                }
            }
            var payloads: [(step: Int, count: Int, data: Data)] = []
            var levelStep = FolderWaveformCache.step, levelCount = count
            while true {
                var payload = Data(capacity: levelCount * 12)
                for value in values {
                    var high = WaveformPeakCodec.encode(value.x).littleEndian, low = WaveformPeakCodec.encode(value.y).littleEndian
                    withUnsafeBytes(of: &high) { payload.append(contentsOf: $0) }
                    withUnsafeBytes(of: &low) { payload.append(contentsOf: $0) }
                }
                payloads.append((levelStep, levelCount, payload))
                if levelCount == 1 { break }
                let nextCount = (levelCount + 3) / 4
                var reduced = [SIMD2<Float>](repeating: SIMD2(-Float.infinity, Float.infinity), count: nextCount * 3)
                for index in 0..<levelCount {
                    for channel in 0..<3 {
                        let source = values[index * 3 + channel], target = (index / 4) * 3 + channel
                        reduced[target].x = max(reduced[target].x, source.x)
                        reduced[target].y = min(reduced[target].y, source.y)
                    }
                }
                values = reduced; levelCount = nextCount; levelStep *= 4
            }
            var data = Data("JFS2".utf8); data.append(Data(fingerprint.utf8))
            func append(_ number: Int) { var value = UInt32(number).littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
            append(3); append(payloads.count)
            var offset = 76 + payloads.count * 12
            for level in payloads { append(level.step); append(level.count); append(offset); offset += level.data.count }
            for level in payloads { data.append(level.data) }
            return data
        }
        func at(step requested: Int) -> TimelineAudioWaveform.VertexBlock {
            let step = max(FolderWaveformCache.step, requested)
            let level = levels.last { $0.step <= step } ?? levels[0]
            let frames = Int(pageSeconds * rate), count = (frames + step - 1) / step
            var channels = [[SIMD2<Float>]](repeating: [], count: 3)
            data.withUnsafeBytes { raw in
                func value(_ offset: Int) -> Float { WaveformPeakCodec.decode(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))) }
                for channel in 0..<3 {
                    channels[channel].reserveCapacity(count * 2)
                    for bucket in 0..<count {
                        let first = bucket * step / level.step, last = min(level.count, (bucket + 1) * step / level.step)
                        var high = -Float.infinity, low = Float.infinity
                        for index in first..<last {
                            let offset = level.offset + (index * 3 + channel) * 4
                            high = max(high, value(offset)); low = min(low, value(offset + 2))
                        }
                        let x = Float(min(frames - 1, bucket * step))
                        channels[channel].append(SIMD2(x, -high))
                        channels[channel].append(SIMD2(Float(min(frames, (bucket + 1) * step)), -low))
                    }
                }
            }
            return TimelineAudioWaveform.VertexBlock(channels: channels, start: start, end: start + Int64(frames), step: step, rate: rate, key: key + ":peaks2:\(step)", isPeakEnvelope: true)
        }
    }
    private let cache = NSCache<NSString, Entry>()
    private let lastReadyPages = NSCache<NSString, Entry>()
    private let vertices = NSCache<NSString, TimelineAudioWaveform.VertexBlock>()
    private func drawing(_ entry: Entry, step: Int) -> TimelineAudioWaveform.VertexBlock {
        let key = "\(entry.key):\(max(Self.step, step))" as NSString
        if let hit = vertices.object(forKey: key) { return hit }
        let block = entry.at(step: step)
        vertices.setObject(block, forKey: key, cost: block.cost)
        return block
    }
    private let worker = DispatchQueue(label: "jaras.folder.waveform", qos: .utility)
    private var pending = Set<String>()
    private var used = Set<String>()
    private var requested = Set<String>()
    private var failed = Set<String>()
    private var pinned: [String: Entry] = [:]
    private var projectPages: [String: Entry] = [:]
    private var projectPageKeys: [String: String] = [:]
    private struct Stored: Codable {
        let version: Int
        let fingerprint: String
        let channels: [Data]
    }
    private struct FileVersion: Codable {
        let source: Source
        let size: Int64
        let modified: Double
    }
    static func diskCacheURL(_ request: Request) -> URL? {
        guard let source = request.sources.first else { return nil }
        var directory = TimelineAudioWaveform.diskCacheURL(source.url).deletingLastPathComponent()
        while directory.lastPathComponent != "WF" && directory.path != "/" { directory.deleteLastPathComponent() }
        guard directory.path != "/" else { return nil }
        return directory.appendingPathComponent("Sums", isDirectory: true)
            .appendingPathComponent(request.folder.uuidString, isDirectory: true)
            .appendingPathComponent("\(request.page).waveform")
    }
    private static func fingerprint(_ request: Request) -> String? {
        let versions: [FileVersion] = request.sources.compactMap { source in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: source.url.path),
                  let size = attributes[.size] as? NSNumber, let modified = attributes[.modificationDate] as? Date else { return nil }
            return FileVersion(source: source, size: size.int64Value, modified: modified.timeIntervalSinceReferenceDate)
        }
        guard versions.count == request.sources.count else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(versions) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    /// Sums cannot be recovered by adding peak envelopes: phase cancellation
    /// requires PCM once. Persist that result too, then reopen from .waveform.
    static func loadOrRender(_ request: Request, key: String) -> TimelineAudioWaveform.VertexBlock? {
        var readers: [URL: Reader] = [:]
        return loadEntry(request, key: key, readers: &readers)?.at(step: step)
    }
    private static func loadEntry(_ request: Request, key: String, readers: inout [URL: Reader], cancelled: () -> Bool = { false }) -> Entry? {
        guard !cancelled() else { return nil }
        let destination = diskCacheURL(request), version = fingerprint(request)
        let start = Int64(Double(request.page) * pageSeconds * rate), end = start + Int64(pageSeconds * rate)
        let activeRanges = prepare(folder: request.folder, sources: request.sources, page: request.page).activeRanges
        if let destination, let version, let data = try? Data(contentsOf: destination, options: .alwaysMapped),
           let stored = Entry(data: data, start: start, key: key, fingerprint: version, activeRanges: activeRanges) { return stored }
        var base: TimelineAudioWaveform.VertexBlock?
        // Migrate v1 signed sums from their existing vertices. Never remix a
        // valid older cache merely to change the storage representation.
        if let destination, let version, let data = try? Data(contentsOf: destination),
           let stored = try? PropertyListDecoder().decode(Stored.self, from: data),
           stored.version == 1, stored.fingerprint == version, stored.channels.count == 3,
           stored.channels.allSatisfy({ !$0.isEmpty && $0.count % 8 == 0 && $0.count <= (Int(pageSeconds * rate) / step + 2) * 32 }) {
            let channels = stored.channels.map { data in
                data.withUnsafeBytes { raw in
                    stride(from: 0, to: raw.count, by: 8).map { raw.loadUnaligned(fromByteOffset: $0, as: SIMD2<Float>.self) }
                }
            }
            let valid = channels.allSatisfy { points in
                points.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.x < Float(pageSeconds * rate) } &&
                    zip(points, points.dropFirst()).allSatisfy { $0.x <= $1.x }
            }
            if valid { base = TimelineAudioWaveform.VertexBlock(channels: channels, start: start, end: end, step: step, rate: rate, key: key) }
        }
        guard let result = base ?? render(request, key: key, readers: &readers, cancelled: cancelled) else { return nil }
        let identifier = version ?? String(repeating: "0", count: 64)
        let data = Entry.encoded(result, fingerprint: identifier)
        if let destination, version != nil, fingerprint(request) == version {
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? data.write(to: destination, options: .atomic)) != nil,
               let mapped = try? Data(contentsOf: destination, options: .alwaysMapped),
               let entry = Entry(data: mapped, start: start, key: key, fingerprint: identifier, activeRanges: activeRanges) {
                return entry
            }
        }
        return Entry(data: data, start: start, key: key, fingerprint: identifier, activeRanges: activeRanges)
    }
    @MainActor func preload(_ groups: [(folder: UUID, sources: [Source])], cancelled: @escaping @Sendable () -> Bool = { false }, progress: @escaping @MainActor (Int, Int) -> Void = { _, _ in }) async {
        let prepared: ([String: Entry], [String: String]) = await withCheckedContinuation { continuation in
            worker.async(qos: .userInitiated) {
                let progressLock = NSLock()
                var percentages = Array(repeating: 0, count: groups.count)
                // Each group owns its readers. Pages within a group stay ordered
                // so compressed audio decodes sequentially instead of seeking.
                let results = WaveformPreparation.map(Array(groups.enumerated())) { groupIndex, group in
                    var pages: [String: Entry] = [:], keys: [String: String] = [:]
                    guard !cancelled() else { return (pages, keys) }
                    var readers: [URL: Reader] = [:]
                    var indices = Set<Int>()
                    for source in group.sources where source.gain != 0 && source.duration > 0 {
                        let first = max(0, Int(floor(source.start / Self.pageSeconds)))
                        let last = max(first, Int(ceil((source.start + source.duration) / Self.pageSeconds)) - 1)
                        indices.formUnion(first...last)
                    }
                    for (pageIndex, index) in indices.sorted().enumerated() {
                        if cancelled() { break }
                        autoreleasepool {
                            let page = Self.prepare(folder: group.folder, sources: group.sources, page: index)
                            let active = Set(page.request.sources.map(\.url))
                            readers = readers.filter { active.contains($0.key) }
                            guard let entry = Self.loadEntry(page.request, key: page.key, readers: &readers, cancelled: cancelled) else { return }
                            pages[page.key] = entry
                            keys["\(group.folder):\(index)"] = page.key
                        }
                        let percent = (pageIndex + 1) * 100 / max(1, indices.count)
                        progressLock.lock()
                        if percent != percentages[groupIndex] {
                            percentages[groupIndex] = percent
                            let done = percentages.reduce(0, +)
                            DispatchQueue.main.async { if !cancelled() { progress(done, groups.count * 100) } }
                        }
                        progressLock.unlock()
                    }
                    if indices.isEmpty {
                        progressLock.lock()
                        percentages[groupIndex] = 100
                        let done = percentages.reduce(0, +)
                        DispatchQueue.main.async { progress(done, groups.count * 100) }
                        progressLock.unlock()
                    }
                    return (pages, keys)
                }
                var pages: [String: Entry] = [:], keys: [String: String] = [:]
                for result in results {
                    pages.merge(result.0) { _, next in next }
                    keys.merge(result.1) { _, next in next }
                }
                continuation.resume(returning: (pages, keys))
            }
        }
        guard !cancelled() else { return }
        projectPages = prepared.0; projectPageKeys = prepared.1
        failed.removeAll()
        revision &+= 1
    }
    init() {
        cache.totalCostLimit = 16 * 1024 * 1024; lastReadyPages.totalCostLimit = 8 * 1024 * 1024
        vertices.totalCostLimit = 16 * 1024 * 1024
    }
    func beginFrame() { used.removeAll(keepingCapacity: true); requested.removeAll(keepingCapacity: true) }
    func endFrame() {
        pinned = pinned.filter { used.contains($0.key) }
        failed.formIntersection(requested)
    }
    /// Only a complete visible replacement becomes presentation state. Worker
    /// completions can arrive page by page without painting a left-to-right gain
    /// change. The retained ranges belong to the retained samples as well.
    func drawing(pages: [PreparedPage], pixelsPerSecond: Double, presentation: Presentation) -> [PresentedPage] {
        guard let folder = pages.first?.request.folder else { return [] }
        if presentation.folder != folder {
            presentation.folder = folder
            presentation.displayed.removeAll()
            presentation.replacements.removeAll()
        }
        let requestedKeys = Set(pages.map(\.key)), visiblePages = Set(pages.map { $0.request.page })
        requested.formUnion(requestedKeys)
        presentation.replacements = presentation.replacements.filter { requestedKeys.contains($0.key) }
        presentation.displayed = presentation.displayed.filter { visiblePages.contains($0.key) }
        var complete = true
        for page in pages where !page.request.sources.isEmpty {
            if let entry = presentation.replacements[page.key] ?? readyEntry(page.key) {
                // Strongly retain each completed candidate: a large visible set
                // must be able to finish even if it exceeds the ordinary cache.
                presentation.replacements[page.key] = entry
            } else {
                complete = false
                enqueue(page)
            }
        }
        if complete {
            var next: [Int: Entry] = [:]
            for page in pages where !page.request.sources.isEmpty {
                guard let entry = presentation.replacements[page.key] else { continue }
                next[page.request.page] = entry
                promote(entry, page: page.request.page, folder: folder)
            }
            presentation.displayed = next
            presentation.replacements.removeAll(keepingCapacity: true)
        } else {
            // Panning may expose another page while a gain edit is pending.
            // Reuse its preloaded previous sum/ranges without promoting any
            // newly completed candidate into the middle of the old curve.
            for page in pages where presentation.displayed[page.request.page] == nil {
                if let previous = previousEntry(folder: folder, page: page.request.page) {
                    presentation.displayed[page.request.page] = previous
                }
            }
        }
        let step = TimelineAudioWaveform.step(rate: Self.rate, pixelsPerSecond: pixelsPerSecond)
        return presentation.displayed.sorted { $0.key < $1.key }.map { page, entry in
            used.insert(entry.key); pinned[entry.key] = entry
            return PresentedPage(page: page, block: drawing(entry, step: step), activeRanges: entry.activeRanges)
        }
    }
    private func readyEntry(_ key: String) -> Entry? {
        projectPages[key] ?? pinned[key] ?? cache.object(forKey: key as NSString)
    }
    private func previousEntry(folder: UUID, page: Int) -> Entry? {
        let pageKey = "\(folder):\(page)"
        return projectPageKeys[pageKey].flatMap { projectPages[$0] } ?? lastReadyPages.object(forKey: pageKey as NSString)
    }
    private func promote(_ entry: Entry, page: Int, folder: UUID) {
        let pageKey = "\(folder):\(page)"
        if let previous = projectPageKeys[pageKey], previous != entry.key {
            projectPages.removeValue(forKey: previous); projectPages[entry.key] = entry
            projectPageKeys[pageKey] = entry.key
        }
        used.insert(entry.key); pinned[entry.key] = entry
        lastReadyPages.setObject(entry, forKey: pageKey as NSString, cost: entry.cost)
    }
    func block(folder: UUID, sources: [Source], page: Int, pixelsPerSecond: Double) -> TimelineAudioWaveform.VertexBlock? {
        block(prepared: Self.prepare(folder: folder, sources: sources, page: page), pixelsPerSecond: pixelsPerSecond)
    }
    func block(prepared: PreparedPage, pixelsPerSecond: Double) -> TimelineAudioWaveform.VertexBlock? {
        guard !prepared.request.sources.isEmpty else { return nil }
        let request = prepared.request, key = prepared.key
        used.insert(key)
        requested.insert(key)
        if let hit = readyEntry(key) {
            promote(hit, page: request.page, folder: request.folder)
            return drawing(hit, step: TimelineAudioWaveform.step(rate: Self.rate, pixelsPerSecond: pixelsPerSecond))
        }
        let fallback = previousEntry(folder: request.folder, page: request.page).map {
            drawing($0, step: TimelineAudioWaveform.step(rate: Self.rate, pixelsPerSecond: pixelsPerSecond))
        }
        enqueue(prepared)
        return fallback
    }
    private func enqueue(_ prepared: PreparedPage) {
        let request = prepared.request, key = prepared.key
        guard !failed.contains(key), pending.count < 3, pending.insert(key).inserted else { return }
        worker.async { [weak self] in
            let value = autoreleasepool {
                var readers: [URL: Reader] = [:]
                return Self.loadEntry(request, key: key, readers: &readers)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending.remove(key)
                if let value { self.cache.setObject(value, forKey: key as NSString, cost: value.cost) }
                else if self.requested.contains(key) { self.failed.insert(key) }
                // Only the folder layer observes this cache, not the entire grid.
                self.revision &+= 1
            }
        }
    }
    /// Original signed PCM is summed before reducing to extrema. Opposite-phase
    /// items cancel correctly; overlapping peak envelopes would not do that.
    static func render(_ request: Request, key: String) -> TimelineAudioWaveform.VertexBlock? {
        var readers: [URL: Reader] = [:]
        return render(request, key: key, readers: &readers)
    }
    private static func render(_ request: Request, key: String, readers: inout [URL: Reader], cancelled: () -> Bool = { false }) -> TimelineAudioWaveform.VertexBlock? {
        let start = Double(request.page) * pageSeconds
        let count = Int(pageSeconds * rate)
        var left = [Float](repeating: 0, count: count)
        var right = left
        for source in request.sources where source.gain != 0 && source.rate > 0 {
            guard !cancelled() else { return nil }
            guard let reader = readers[source.url] ?? (try? Reader(source.url)) else { return nil }
            readers[source.url] = reader
            let first = max(0, Int(ceil((source.start - start) * rate)))
            let last = min(count, Int(ceil((source.start + source.duration - start) * rate)))
            guard last > first else { continue }
            let leftGain = Float(source.gain * (source.pan > 0 ? 1 - source.pan : 1))
            let rightGain = Float(source.gain * (source.pan < 0 ? 1 + source.pan : 1))
            // Most imported stems have no loop/envelope. Mix a decoder page
            // at a time with Accelerate, including sample-rate interpolation.
            // Never invoke a Swift reader and ARC operations for every sample.
            if source.loopLength == nil && source.fadeIn == 0 && source.fadeOut == 0 {
                let initial = (source.offset + (start + Double(first) / rate - source.start) * source.rate) * reader.rate
                guard reader.accumulate(initial: initial, increment: source.rate * reader.rate / rate,
                                        range: first..<last, leftGain: leftGain, rightGain: rightGain,
                                        mode: source.mode, leftOutput: &left, rightOutput: &right, cancelled: cancelled) else { return nil }
                continue
            }
            for index in first..<last {
                if index % 4096 == 0 && cancelled() { return nil }
                let time = start + Double(index) / rate
                var position = source.offset + (time - source.start) * source.rate
                if let length = source.loopLength, length > 0 {
                    let origin = source.loopStart ?? 0
                    position = origin + ((position - origin).truncatingRemainder(dividingBy: length) + length).truncatingRemainder(dividingBy: length)
                }
                let sample = reader.sample(position * reader.rate)
                var l = sample.0, r = sample.1
                switch source.mode {
                case 1: r = l
                case 2: l = r
                case 3: l = (l + r) * 0.5; r = l
                default: break
                }
                let elapsed = time - source.fadeStart
                var envelope = 1.0
                if source.fadeIn > 0 { envelope *= min(1, max(0, elapsed / source.fadeIn)) }
                if source.fadeOut > 0 { envelope *= min(1, max(0, (source.fadeDuration - elapsed) / source.fadeOut)) }
                left[index] += l * leftGain * Float(envelope)
                right[index] += r * rightGain * Float(envelope)
            }
            guard !reader.failed else { return nil }
        }
        return TimelineAudioWaveform.VertexBlock(pcm: TimelineAudioWaveform.PCM(channels: [left, right]),
            start: Int64(start * rate), span: count, step: step, rate: rate, key: key)
    }
    final class Reader {
        let file: AVAudioFile
        let buffer: AVAudioPCMBuffer
        let rate: Double
        let length: Int64
        let stride: Int
        let left: UnsafeMutablePointer<Float>
        let right: UnsafeMutablePointer<Float>
        private let capacity: Int64 = 65_536
        var pageStart: Int64 = -1
        var count = 0
        private(set) var failed = false
        private(set) var decodedPageCount = 0
        private var overlapIndex: Int64 = -1
        private var overlap: (Float, Float) = (0, 0)
        init(_ url: URL) throws {
            file = try AVAudioFile(forReading: url)
            rate = file.processingFormat.sampleRate
            length = file.length
            buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536)!
            stride = buffer.stride
            left = buffer.floatChannelData![0]
            right = buffer.floatChannelData![min(1, Int(buffer.format.channelCount) - 1)]
        }
        private func load(_ page: Int64) -> Bool {
            guard page != pageStart else { return count > 0 }
            do {
                // Keep the interpolation seam when a fractional rate asks for
                // the previous page's last sample again. Seeking back here can
                // restart a compressed decoder from the beginning of the file.
                if count > 0 && page == pageStart + Int64(count) {
                    overlapIndex = page - 1
                    overlap = (left[(count - 1) * stride], right[(count - 1) * stride])
                } else { overlapIndex = -1 }
                // Adjacent pages read sequentially. Seeking backwards by the
                // interpolation overlap repeatedly restarted the MP3 decoder.
                if file.framePosition != page { file.framePosition = page }
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(capacity, length - page)))
                decodedPageCount += 1
                pageStart = page; count = Int(buffer.frameLength)
                return count > 0
            } catch { count = 0; failed = true; return false }
        }
        func accumulate(initial: Double, increment: Double, range: Range<Int>, leftGain: Float, rightGain: Float,
                        mode: Int, leftOutput: inout [Float], rightOutput: inout [Float], cancelled: () -> Bool) -> Bool {
            guard initial.isFinite, increment.isFinite, increment > 0 else { return false }
            var output = range.lowerBound
            var positions = [Float](repeating: 0, count: 65_536)
            var precisePositions = [Double](repeating: 0, count: 65_536)
            var l = positions, r = positions
            return leftOutput.withUnsafeMutableBufferPointer { outL in
                rightOutput.withUnsafeMutableBufferPointer { outR in
                    while output < range.upperBound {
                        if cancelled() { return false }
                        let frame = initial + Double(output - range.lowerBound) * increment
                        if frame < 0 { output += min(range.upperBound - output, max(1, Int(ceil(-frame / increment)))); continue }
                        if frame >= Double(length) { break }
                        let index = Int64(frame), page = index / capacity * capacity
                        if index == overlapIndex && pageStart == index + 1 && count > 0 {
                            let value = sample(frame)
                            let a = mode == 2 ? value.1 : mode == 3 ? (value.0 + value.1) * 0.5 : value.0
                            let b = mode == 1 ? value.0 : mode == 3 ? a : value.1
                            outL[output] += a * leftGain; outR[output] += b * rightGain
                            output += 1; continue
                        }
                        guard load(page) else { return !failed }
                        let local = frame - Double(pageStart)
                        let available = max(0, Int(floor((Double(count - 1) - local) / increment)))
                        let n = min(65_536, range.upperBound - output, available)
                        if n == 0 {
                            let value = sample(frame)
                            let a = mode == 2 ? value.1 : mode == 3 ? (value.0 + value.1) * 0.5 : value.0
                            let b = mode == 1 ? value.0 : mode == 3 ? a : value.1
                            outL[output] += a * leftGain; outR[output] += b * rightGain
                            output += 1; continue
                        }
                        let length = vDSP_Length(n)
                        if abs(increment - 1) < 1e-12 && abs(local - local.rounded()) < 1e-7 {
                            let offset = Int(local.rounded()) * stride
                            l.withUnsafeMutableBufferPointer { cblas_scopy(Int32(n), left + offset, Int32(stride), $0.baseAddress!, 1) }
                            r.withUnsafeMutableBufferPointer { cblas_scopy(Int32(n), right + offset, Int32(stride), $0.baseAddress!, 1) }
                        } else {
                            // A long Float ramp accumulates enough error to
                            // shift transients by a sample. Build coordinates in
                            // Double, then convert once for vector interpolation.
                            var origin = local, step = increment
                            vDSP_vrampD(&origin, &step, &precisePositions, 1, length)
                            vDSP_vdpsp(precisePositions, 1, &positions, 1, length)
                            vDSP_vlint(left, &positions, 1, &l, 1, length, vDSP_Length(count))
                            vDSP_vlint(right, &positions, 1, &r, 1, length, vDSP_Length(count))
                        }
                        switch mode {
                        case 1: r = l
                        case 2: l = r
                        case 3:
                            vDSP_vadd(l, 1, r, 1, &l, 1, length)
                            var half: Float = 0.5; vDSP_vsmul(l, 1, &half, &l, 1, length); r = l
                        default: break
                        }
                        var lg = leftGain, rg = rightGain
                        l.withUnsafeBufferPointer { vDSP_vsma($0.baseAddress!, 1, &lg, outL.baseAddress! + output, 1, outL.baseAddress! + output, 1, length) }
                        r.withUnsafeBufferPointer { vDSP_vsma($0.baseAddress!, 1, &rg, outR.baseAddress! + output, 1, outR.baseAddress! + output, 1, length) }
                        output += n
                    }
                    return !failed
                }
            }
        }
        func sample(_ frame: Double) -> (Float, Float) {
            guard frame >= 0, frame < Double(length), frame.isFinite else { return (0, 0) }
            let index = Int64(frame), page = index / capacity * capacity
            if index == overlapIndex && pageStart == index + 1 && count > 0 {
                let blend = Float(frame - Double(index))
                return (overlap.0 + (left[0] - overlap.0) * blend,
                        overlap.1 + (right[0] - overlap.1) * blend)
            }
            guard load(page) else { return (0, 0) }
            let local = Int(index - pageStart)
            guard local < count else { return (0, 0) }
            let l = left[local * stride], r = right[local * stride]
            let blend = Float(frame - Double(index))
            if blend == 0 || index + 1 >= length { return (l, r) }
            if local + 1 < count {
                return (l + (left[(local + 1) * stride] - l) * blend,
                        r + (right[(local + 1) * stride] - r) * blend)
            }
            guard load(page + capacity) else { return (l, r) }
            return (l + (left[0] - l) * blend, r + (right[0] - r) * blend)
        }
    }
}

extension FolderWaveformCache {
    static func sources(song: Song, folder: Track, directory: URL, missing: Set<String>) -> [Source] {
        let byID = Dictionary(uniqueKeysWithValues: song.tracks.map { ($0.id, $0) })
        let sections = song.tempoMarkersAffectAudio ? song.tempoSections(until: song.duration) : []
        var result: [Source] = []
        for track in song.tracks where track.kind == .standard && track.id != folder.id {
            var parent = track.parentTrackID, included = false, visited = Set<UUID>()
            var gain = track.mute ? 0 : track.volume * (track.phaseInverted == true ? -1 : 1)
            while let id = parent, visited.insert(id).inserted, let group = byID[id] {
                gain *= group.mute ? 0 : group.volume * (group.phaseInverted == true ? -1 : 1)
                if id == folder.id { included = true; break }
                parent = group.parentTrackID
            }
            guard included else { continue }
            for clip in track.clips {
                guard let file = clip.audioFile ?? track.audioFile, !missing.contains(file.path) else { continue }
                let fragments = sections.isEmpty ? [clip] : song.tempoAudioSegments(clip, sections: sections)
                for fragment in fragments {
                    result.append(Source(url: directory.appendingPathComponent(file.path), start: fragment.startTime,
                        duration: fragment.duration, offset: fragment.sourceOffset, rate: fragment.audioRate,
                        loopStart: fragment.loopStart, loopLength: fragment.loopLength,
                        gain: clip.muted == true ? 0 : gain * (clip.gain ?? 1) * (clip.normalizationGain ?? 1), pan: track.pan,
                        fadeIn: fragment.fadeIn ?? 0, fadeOut: fragment.fadeOut ?? 0,
                        fadeStart: fragment.fadeTimelineStart ?? fragment.startTime,
                        fadeDuration: fragment.fadeTimelineDuration ?? fragment.duration, mode: fragment.channelMode ?? 0))
                }
            }
        }
        return result
    }
}
