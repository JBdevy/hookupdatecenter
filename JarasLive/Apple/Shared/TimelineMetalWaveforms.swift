import SwiftUI

/// Native scrolling publishes origins in 512-point buckets. Cover that entire
/// unpublished interval plus a small lookahead, instead of preparing a second
/// screen of audio on every zoom frame. Large jumps flush the destination
/// before the native clip moves (see SidebarScrollProbe).
enum TimelineWaveformCoverage {
    static let scrollBucket: CGFloat = 512
    static let guardBand: CGFloat = 128
    static var trailingReserve: CGFloat { scrollBucket + guardBand }
    static func preparedRect(visibleRect: CGRect, documentSize: CGSize) -> CGRect {
        let left = min(documentSize.width, max(0, visibleRect.minX - guardBand))
        let top = min(documentSize.height, max(0, visibleRect.minY - guardBand))
        let right = min(documentSize.width, ceil((visibleRect.maxX + trailingReserve) / guardBand) * guardBand)
        let bottom = min(documentSize.height, ceil((visibleRect.maxY + trailingReserve) / guardBand) * guardBand)
        return CGRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
    }
}

/// File kind is already known. The default Foundation path append performs an
/// lstat to infer it; doing that per item on every zoom frame stalls the UI.
final class TimelineMediaURLCache {
    final class Source {
        let url: URL
        let path: String
        private var retainedHeader: TimelineAudioWaveform.Header?
        private var headerCache: TimelineAudioWaveform?
        private var headerRevision: UInt64?
        private var contentRevision: Int?

        init(url: URL, path: String) { self.url = url; self.path = path }

        /// Zooms reuse the immutable source header without converting its path
        /// to NSString. Readiness and structural edits revisit the canonical
        /// cache so source replacement at the same URL is observed. Recording
        /// keeps the existing timed refresh on every request.
        func header(cache: TimelineAudioWaveform, refresh: Bool, contentRevision: Int, readinessRevision: UInt64? = nil) -> TimelineAudioWaveform.Header? {
            let revision = readinessRevision ?? cache.revision
            if !refresh, headerCache === cache, headerRevision == revision,
               self.contentRevision == contentRevision, let retainedHeader {
                return retainedHeader
            }
            let value = cache.header(url, refresh: refresh, sourcePath: path)
            retainedHeader = value
            headerCache = cache
            headerRevision = revision
            self.contentRevision = contentRevision
            return value
        }
    }
    private var directory: URL?
    private var urls: [String: Source] = [:]
    private var clipDirectory: URL?
    private var clipSources: [UUID: Source] = [:]

    /// A native configuration owns immutable clip/file values. Reset even when
    /// its directory is unchanged: an edit can replace the source of one UUID.
    func prepareClipRevision(directory: URL?) {
        clipDirectory = directory
        clipSources.removeAll(keepingCapacity: directory != nil)
        if directory == nil {
            self.directory = nil
            urls.removeAll()
        }
    }
    func resolveClipSource(_ id: UUID, path: @autoclosure () -> String) -> Source? {
        if let source = clipSources[id] { return source }
        guard let directory = clipDirectory else { return nil }
        let source = resolveSource(path(), directory: directory)
        clipSources[id] = source
        return source
    }
    func resolve(_ path: String, directory: URL) -> URL {
        resolveSource(path, directory: directory).url
    }
    func resolveSource(_ path: String, directory: URL) -> Source {
        if self.directory != directory { self.directory = directory; urls.removeAll(keepingCapacity: true) }
        if let source = urls[path] { return source }
        let url = directory.appendingPathComponent(path, isDirectory: false)
        // Percent decoding a long Unicode URL is measurable on each zoom
        // frame. Retain its immutable lookup path beside the existing URL.
        let source = Source(url: url, path: url.path)
        urls[path] = source
        return source
    }
}

/// Audio coordinates remain independent of zoom. Only the small transform and
/// clipping records change during a gesture; source vertices stay on the GPU.
struct TimelineWaveformItem {
    let clip: AudioClip
    let fragments: [AudioClip]
    let url: URL
    let rect: CGRect
    let gray: Float
    var sourcePath: String? = nil
    var mediaSource: TimelineMediaURLCache.Source? = nil
}

final class TimelineWaveformVertexOwner {
    private struct Pinned {
        var blocks: [TimelineAudioWaveform.VertexBlock]
        let source: String
        let step: Int
        var reserveFirst: Int = -1
        var reserveLast: Int = -1
        var reserveRevision: UInt64?
        var reserveComplete = false
        var reserveDecodeDirections = 0
        var visibleFirst: Double?
        var visibleLast: Double?
    }
    private var pinned: [String: Pinned] = [:]
    private var used = Set<String>()
    private var detailedSources = Set<String>()
    private var usedDetailSources = Set<String>()
    func beginFrame() {
        used.removeAll(keepingCapacity: true)
        usedDetailSources.removeAll(keepingCapacity: true)
    }
    func endFrame() {
        pinned = pinned.filter { used.contains($0.key) }
        detailedSources.formIntersection(usedDetailSources)
    }

    private static func covers(_ blocks: [TimelineAudioWaveform.VertexBlock], first: Double, last: Double) -> Bool {
        guard let head = blocks.first, Double(head.start) <= first,
              let tail = blocks.last, Double(tail.end) >= last else { return false }
        return zip(blocks, blocks.dropFirst()).allSatisfy { $0.end >= $1.start }
    }
    /// Only combine one PCM level. Different detail steps have nonnested block
    /// boundaries; combining those blocks can either overlap or leave a hole.
    private static func merge(_ old: [TimelineAudioWaveform.VertexBlock], _ new: [TimelineAudioWaveform.VertexBlock]) -> [TimelineAudioWaveform.VertexBlock] {
        if new.isEmpty { return old }
        if old.isEmpty { return new }
        var result: [TimelineAudioWaveform.VertexBlock] = []
        result.reserveCapacity(old.count + new.count)
        var a = 0, b = 0
        while a < old.count && b < new.count {
            if old[a].start < new[b].start { result.append(old[a]); a += 1 }
            else {
                if old[a].start == new[b].start { a += 1 }
                result.append(new[b]); b += 1
            }
        }
        result.append(contentsOf: old[a...]); result.append(contentsOf: new[b...])
        return result
    }

    /// Keep two cached blocks beside the visible interval. New zoom levels do
    /// not decode this reserve: only a same-level pan toward a block boundary
    /// enables bounded reads in that direction. A complete retained reserve is
    /// independent of global cache revisions and transient cache eviction.
    private func reserve(_ entry: inout Pinned, cache: TimelineAudioWaveform, url: URL,
                         header: TimelineAudioWaveform.Header, first: Double, last: Double) {
        let span = TimelineAudioWaveform.span(step: entry.step)
        let firstBlock = Int(floor(first / Double(span)))
        let lastBlock = max(firstBlock, Int(ceil(last / Double(span))) - 1)
        let reserveFirst = max(0, firstBlock - 2)
        let reserveLast = min(Int((header.frames - 1) / Int64(span)), lastBlock + 2)
        var panDirection = 0
        if let previousFirst = entry.visibleFirst, let previousLast = entry.visibleLast,
           abs((last - first) - (previousLast - previousFirst)) <= max(1, (last - first) * 0.000001) {
            if first > previousFirst + 0.25, Double((lastBlock + 1) * span) - last <= Double(span) / 2 { panDirection = 2 }
            if first < previousFirst - 0.25, first - Double(firstBlock * span) <= Double(span) / 2 { panDirection = 1 }
        }
        entry.visibleFirst = first; entry.visibleLast = last
        let changed = entry.reserveFirst != reserveFirst || entry.reserveLast != reserveLast
        if changed {
            entry.reserveComplete = false
            entry.reserveDecodeDirections = 0
        }
        let directions = entry.reserveDecodeDirections | panDirection
        guard !entry.reserveComplete,
              changed || entry.reserveRevision != cache.revision || directions != entry.reserveDecodeDirections else { return }
        entry.reserveFirst = reserveFirst; entry.reserveLast = reserveLast; entry.reserveRevision = cache.revision
        entry.reserveDecodeDirections = directions
        let reserveStart = Double(reserveFirst * span)
        let reserveEnd = min(Double(header.frames), Double((reserveLast + 1) * span))
        entry.blocks = TimelineAudioWaveform.visibleVertexBlocks(entry.blocks, from: reserveStart, to: reserveEnd)
        // The owner may already hold these blocks after a pan, even if NSCache
        // has evicted them. Never recreate an immutable block it still owns.
        if Self.covers(entry.blocks, first: reserveStart, last: reserveEnd) {
            entry.reserveComplete = true
            return
        }
        let scale = header.rate / Double(entry.step * 2)
        func extend(_ first: Int, _ last: Int, direction: Int) {
            guard last >= first else { return }
            let start = Double(first * span), end = min(Double(header.frames), Double((last + 1) * span))
            if Self.covers(TimelineAudioWaveform.visibleVertexBlocks(entry.blocks, from: start, to: end), first: start, last: end) { return }
            let ready = cache.vertexDrawing(url, header: header, start: start / header.rate,
                end: end / header.rate, pixelsPerSecond: scale, prefetch: true, cachedOnly: directions & direction == 0)
            entry.blocks = Self.merge(entry.blocks, ready.blocks)
        }
        extend(reserveFirst, firstBlock - 1, direction: 1)
        extend(lastBlock + 1, reserveLast, direction: 2)
        entry.reserveComplete = Self.covers(entry.blocks, first: reserveStart, last: reserveEnd)
    }

    func blocks(cache: TimelineAudioWaveform, url: URL, header: TimelineAudioWaveform.Header,
                start: Double, end: Double, scale: Double, key: String) -> [TimelineAudioWaveform.VertexBlock] {
        used.insert(key)
        let source = header.cachePrefix ?? "\(url.path):\(header.frames):\(header.rate)"
        let step = TimelineAudioWaveform.step(rate: header.rate, pixelsPerSecond: scale)
        let fine = step < TimelineAudioWaveform.peakFramesPerInterval
        if fine { usedDetailSources.insert(source) }
        let first = max(0, min(Double(header.frames), start * header.rate))
        let last = max(first, min(Double(header.frames), end * header.rate))
        guard last > first else { return [] }
        func visible(_ blocks: [TimelineAudioWaveform.VertexBlock]) -> [TimelineAudioWaveform.VertexBlock] {
            TimelineAudioWaveform.visibleVertexBlocks(blocks, from: first, to: last)
        }
        let previous = pinned[key].flatMap { $0.source == source ? $0 : nil }
        if var entry = previous, entry.step == step {
            let retained = visible(entry.blocks)
            if Self.covers(retained, first: first, last: last) {
                // Compact peak blocks are immutable source geometry too. A
                // zoomed-out clip often fits wholly in the viewport: keep its
                // already owned blocks rather than querying/rebuilding the
                // same peak level on every projection or unrelated revision.
                if fine {
                    reserve(&entry, cache: cache, url: url, header: header, first: first, last: last)
                    pinned[key] = entry
                }
                return retained
            }
        }
        let requested = cache.vertexDrawing(url, header: header, start: start, end: end, pixelsPerSecond: scale)
        if requested.complete && Self.covers(requested.blocks, first: first, last: last) {
            var entry = previous.flatMap { $0.step == step ? $0 : nil } ?? Pinned(blocks: [], source: source, step: step)
            entry.blocks = fine ? Self.merge(entry.blocks, requested.blocks) : requested.blocks
            if fine {
                detailedSources.insert(source)
                reserve(&entry, cache: cache, url: url, header: header, first: first, last: last)
            }
            pinned[key] = entry
            return visible(entry.blocks)
        }
        // A genuine zoom-out returns to the compact pyramid immediately, so a
        // former sample curve cannot grow into millions of overdrawn segments.
        // At fine zoom, the initial envelope is allowed only before PCM exists.
        if !fine || !detailedSources.contains(source) {
            let overview = cache.cachedCoarserVertices(header, url: url, start: start, end: end, requestedStep: step)
            if !overview.isEmpty {
                pinned[key] = Pinned(blocks: overview, source: source, step: overview[0].step)
                return overview
            }
        }
        if fine, var entry = previous, entry.step < TimelineAudioWaveform.peakFramesPerInterval {
            if entry.step == step {
                entry.blocks = Self.merge(entry.blocks, requested.blocks)
            } else if entry.step >= max(1, step / 4),
                      !Self.covers(visible(entry.blocks), first: first, last: last),
                      let head = entry.blocks.first, let tail = entry.blocks.last {
                // While changing levels, reuse only already cached old-level
                // edges (at most four blocks), without starting another decode.
                // Never request a huge old-detail
                // viewport after a large zoom-out. The density guard also stops
                // repeated frames accumulating many already cached fine blocks.
                // The target level is already
                // queued above and replaces this whole curve when complete.
                let span = TimelineAudioWaveform.span(step: entry.step)
                let oldFirst = max(first, Double(head.start - Int64(span * 2)))
                let oldLast = min(last, Double(tail.end + Int64(span * 2)))
                for range in [(oldFirst, min(last, Double(head.start))), (max(first, Double(tail.end)), oldLast)] where range.1 > range.0 {
                    let ready = cache.vertexDrawing(url, header: header, start: range.0 / header.rate,
                        end: range.1 / header.rate, pixelsPerSecond: header.rate / Double(entry.step * 2), prefetch: true, cachedOnly: true)
                    entry.blocks = Self.merge(entry.blocks, ready.blocks)
                }
            }
            let retained = visible(entry.blocks)
            if !retained.isEmpty {
                let span = Double(TimelineAudioWaveform.span(step: entry.step))
                entry.blocks = TimelineAudioWaveform.visibleVertexBlocks(entry.blocks, from: first - span * 2, to: last + span * 2)
                pinned[key] = entry
                return retained
            }
        }
        // Unprepared sources and distant cold pans can display arriving PCM
        // progressively. No prepared envelope is reintroduced after fine detail.
        if fine && !requested.blocks.isEmpty {
            detailedSources.insert(source)
            pinned[key] = Pinned(blocks: requested.blocks, source: source, step: step)
        }
        return requested.blocks
    }
}

struct TimelineMetalWaveformSurface: View {
    @ObservedObject private var cache = TimelineAudioWaveform.shared
    @State private var owner = TimelineWaveformVertexOwner()
    let items: [TimelineWaveformItem]
    let viewport: CGRect
    let scale: Double
    var contentRevision: Int = 0
    var body: some View {
        MetalWaveformView(frame: TimelineMetalWaveformFrameBuilder.make(items: items, viewport: viewport,
            scale: scale, cache: cache, owner: owner, contentRevision: contentRevision))
            .frame(width: viewport.width, height: viewport.height)
            .offset(x: viewport.minX, y: viewport.minY)
            .allowsHitTesting(false)
    }
}

enum TimelineMetalWaveformFrameBuilder {
    private static let unitLine = TimelineAudioWaveform.VertexBlock(channels: [[SIMD2<Float>(0, 0), SIMD2<Float>(1, 0)]], start: 0, end: 1, step: 1, rate: 1, key: "timeline-centerline-unit")
    static func make(items: [TimelineWaveformItem], viewport: CGRect, scale: Double,
                     cache: TimelineAudioWaveform, owner: TimelineWaveformVertexOwner, contentRevision: Int = 0) -> MetalWaveformFrame {
        owner.beginFrame()
        defer { owner.endFrame() }
        var strokes: [MetalWaveformStroke] = []
        guard scale.isFinite, scale > 0, viewport.width > 0, viewport.height > 0 else {
            return MetalWaveformFrame(size: viewport.size, strokes: [])
        }
        let readinessRevision = cache.revision
        for item in items where item.rect.height > 26 && item.rect.intersects(viewport) {
            let loadedHeader: TimelineAudioWaveform.Header?
            if let source = item.mediaSource {
                loadedHeader = source.header(cache: cache, refresh: item.clip.recordingLane != nil,
                    contentRevision: contentRevision, readinessRevision: readinessRevision)
            } else {
                loadedHeader = cache.header(item.url, refresh: item.clip.recordingLane != nil,
                    sourcePath: item.sourcePath)
            }
            guard let header = loadedHeader, header.channels > 0 else { continue }
            let rect = item.rect
            let waveTop = rect.minY + min(GridSelectionItem.bodyInset, rect.height)
            let mode = item.clip.channelMode ?? 0
            let channels = mode == 0 ? header.channels : 1
            let channelHeight = max(0, rect.maxY - waveTop - 2) / Double(channels)
            guard channelHeight > 0 else { continue }
            let amplitude = channelHeight * 0.98 * min(pow(10, 24.0 / 20), max(0, item.clip.gain ?? 1))
            let localItem = rect.offsetBy(dx: -viewport.minX, dy: -viewport.minY)
            var visibleSeams = ClipRepetitionBoundaries(clip: item.clip,
                visible: max(item.clip.startTime, (viewport.minX - 4) / scale)...max(item.clip.startTime, (viewport.maxX + 4) / scale), minimumSpacing: 10 / scale).makeIterator()
            let firstSeam = visibleSeams.next().map { CGFloat($0 * scale - viewport.minX) }
            let seamSpacing = item.clip.loopLength.map { CGFloat(max(1, ceil(10 / ($0 / item.clip.audioRate * scale))) * $0 / item.clip.audioRate * scale) }
            for (fragmentIndex, fragment) in item.fragments.enumerated() {
                let rate = fragment.audioRate
                guard rate.isFinite, rate > 0 else { continue }
                let first = max(fragment.startTime, max(rect.minX, viewport.minX) / scale)
                let last = min(fragment.startTime + fragment.duration, min(rect.maxX, viewport.maxX) / scale)
                guard last > first else { continue }
                let sourceScale = scale / rate
                let contourWidth = Float(TimelineWaveformStrokeStyle.lineWidth(sampleRate: header.rate, pixelsPerSecond: sourceScale))
                // A subpixel repetition is a continuous band at this scale.
                // Bound work to one period instead of iterating millions of loops.
                if let length = fragment.loopLength, length > 0, length * sourceScale < 1 {
                    let start = max(0, fragment.loopStart ?? 0)
                    let end = min(Double(header.frames) / header.rate, start + length)
                    guard end > start else { continue }
                    // A sub-sample loop can fall between PCM vertices. Keep
                    // its interval extrema, and avoid decoding detail for a
                    // repetition that is rendered only as a continuous band.
                    let summaryScale = min(128 / length, header.rate / Double(TimelineAudioWaveform.peakFramesPerInterval * 2))
                    let blocks = owner.blocks(cache: cache, url: item.url, header: header, start: start, end: end,
                        scale: summaryScale, key: "\(item.clip.id):\(fragmentIndex):subpixel")
                    for channel in 0..<channels {
                        let sourceChannel = mode == 1 ? 0 : mode == 2 ? min(1, header.channels - 1) : mode == 3 && header.channels > 1 ? header.channels : channel
                        var minimum: Float = 0, maximum: Float = 0
                        for block in blocks where sourceChannel < block.channels.count {
                            let points = block.channels[sourceChannel]
                            if block.isPeakEnvelope {
                                // Peaks describe intervals, not isolated sample
                                // positions. A short loop can sit entirely
                                // between both endpoints of the same interval.
                                for index in stride(from: 0, to: points.count - 1, by: 2) {
                                    let first = (Double(block.start) + Double(points[index].x)) / header.rate
                                    let last = (Double(block.start) + Double(points[index + 1].x)) / header.rate
                                    if last > start && first < end {
                                        minimum = min(minimum, points[index].y, points[index + 1].y)
                                        maximum = max(maximum, points[index].y, points[index + 1].y)
                                    }
                                }
                            } else {
                                for vertex in points {
                                    let time = (Double(block.start) + Double(vertex.x)) / header.rate
                                    if time >= start && time <= end { minimum = min(minimum, vertex.y); maximum = max(maximum, vertex.y) }
                                }
                            }
                        }
                        let channelRect = CGRect(x: first * scale, y: waveTop + channelHeight * Double(channel) + 0.5,
                            width: (last - first) * scale, height: max(0, channelHeight - 1)).intersection(rect).intersection(viewport)
                        guard !channelRect.isNull, !channelRect.isEmpty else { continue }
                        let middle = waveTop + channelHeight * (Double(channel) + 0.5) - viewport.minY
                        strokes.append(MetalWaveformStroke(block: unitLine, channel: 0,
                            scale: SIMD2(Float((last - first) * scale), 1),
                            translation: SIMD2(Float(first * scale - viewport.minX), Float(middle) + (minimum + maximum) * Float(amplitude) / 2),
                            clip: channelRect.offsetBy(dx: -viewport.minX, dy: -viewport.minY), color: SIMD4(repeating: item.gray).withAlpha(1), itemRect: localItem,
                            firstSeamX: firstSeam, repeatSpacing: seamSpacing, lineWidth: max(0.5, (maximum - minimum) * Float(amplitude))))
                    }
                    continue
                }
                // Repetitions share immutable source geometry. Resolve it once
                // when a whole period fits the visible interval; querying and
                // pinning the same tiny loop thousands of times wastes a frame.
                // Long periods still request only their visible source range.
                let loopBlocks: [TimelineAudioWaveform.VertexBlock]?
                if let length = fragment.loopLength, length > 0, length / rate <= last - first {
                    let start = max(0, fragment.loopStart ?? 0)
                    let end = min(Double(header.frames) / header.rate, (fragment.loopStart ?? 0) + length)
                    loopBlocks = end > start ? owner.blocks(cache: cache, url: item.url, header: header,
                        start: start, end: end, scale: sourceScale, key: "\(item.clip.id):\(fragmentIndex):period") : []
                } else { loopBlocks = nil }
                var position = first
                while position < last {
                    let relative = fragment.sourceOffset + (position - fragment.startTime) * rate
                    let source: Double, end: Double, repetition: Double
                    if let length = fragment.loopLength, length > 0 {
                        let origin = fragment.loopStart ?? 0
                        let rawPhase = ((relative - origin).truncatingRemainder(dividingBy: length) + length).truncatingRemainder(dividingBy: length)
                        // A computed boundary can land one floating-point ULP
                        // before the loop end. Advancing by that tiny remainder
                        // rounds back to `position`, which would truncate all
                        // subsequent repetitions. Normalize only rounding noise.
                        let tolerance = min(length * 0.000001,
                            max(abs(position).ulp * rate * 8, abs(relative).ulp * 8, length.ulp * 8))
                        let atBoundary = rawPhase <= tolerance || length - rawPhase <= tolerance
                        let phase = atBoundary ? 0 : rawPhase
                        source = origin + phase
                        end = min(last, position + (length - phase) / rate)
                        repetition = atBoundary ? ((relative - origin) / length).rounded() : floor((relative - origin) / length)
                    } else { source = relative; end = last; repetition = 0 }
                    guard end > position else { break }
                    let sourceEnd = min(Double(header.frames) / header.rate, source + (end - position) * rate)
                    if sourceEnd > source {
                        let blocks: [TimelineAudioWaveform.VertexBlock]
                        if let loopBlocks { blocks = loopBlocks }
                        else {
                            let key = "\(item.clip.id):\(fragmentIndex):\(fragment.startTime):\(fragment.sourceOffset):\(repetition)"
                            blocks = owner.blocks(cache: cache, url: item.url, header: header, start: max(0, source), end: sourceEnd, scale: sourceScale, key: key)
                        }
                        for channel in 0..<channels {
                            let sourceChannel = mode == 1 ? 0 : mode == 2 ? min(1, header.channels - 1) : mode == 3 && header.channels > 1 ? header.channels : channel
                            let middle = waveTop + channelHeight * (Double(channel) + 0.5) - viewport.minY
                            let channelRect = CGRect(x: position * scale, y: waveTop + channelHeight * Double(channel) + 0.5,
                                width: (end - position) * scale, height: max(0, channelHeight - 1)).intersection(rect).intersection(viewport)
                            guard !channelRect.isNull, !channelRect.isEmpty else { continue }
                            let localClip = channelRect.offsetBy(dx: -viewport.minX, dy: -viewport.minY)
                            strokes.append(MetalWaveformStroke(block: unitLine, channel: 0,
                                scale: SIMD2(Float(localClip.width), 1), translation: SIMD2(Float(localClip.minX), Float(middle)),
                                clip: localClip, color: SIMD4(repeating: item.gray).withAlpha(0.5), itemRect: localItem,
                                firstSeamX: firstSeam, repeatSpacing: seamSpacing, lineWidth: 0.5))
                            for block in blocks where sourceChannel < block.channels.count {
                                let x = position * scale - viewport.minX + (Double(block.start) / header.rate - source) * sourceScale
                                let right = x + Double(block.end - block.start) / header.rate * sourceScale
                                guard right >= localClip.minX - 2, x <= localClip.maxX + 2 else { continue }
                                strokes.append(MetalWaveformStroke(block: block, channel: sourceChannel,
                                    scale: SIMD2(Float(sourceScale / header.rate), Float(amplitude)), translation: SIMD2(Float(x), Float(middle)),
                                    clip: localClip, color: SIMD4(repeating: item.gray).withAlpha(1), itemRect: localItem,
                                    firstSeamX: firstSeam, repeatSpacing: seamSpacing, lineWidth: block.isPeakEnvelope ? 2 : contourWidth))
                            }
                        }
                    }
                    position = end
                }
            }
        }
        return MetalWaveformFrame(size: viewport.size, strokes: strokes,
            coordinateSpace: MetalWaveformCoordinateSpace(documentOrigin: viewport.origin,
                pixelsPerSecond: scale, contentRevision: contentRevision))
    }
}

private extension SIMD4 where Scalar == Float {
    func withAlpha(_ alpha: Float) -> Self { SIMD4(x, y, z, alpha) }
}
