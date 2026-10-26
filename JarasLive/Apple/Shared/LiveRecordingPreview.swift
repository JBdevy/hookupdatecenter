import SwiftUI
import AVFoundation
import Darwin
struct RecordingPreviewTake {
    var start: Double
    var duration: Double
    var channels: [[Double]]
    var waveform: LiveRecordedWaveform? = nil
}
@MainActor final class LiveRecordingPreview: ObservableObject {
    static let shared = LiveRecordingPreview()
    @Published var takes: [UUID: RecordingPreviewTake] = [:]
}
/// Waveform updates do not invalidate the grid; only a change of lane does.
@MainActor final class RecordingLaneLayout: ObservableObject {
    static let shared = RecordingLaneLayout()
    struct Reservation {
        let track: UUID
        var clip: AudioClip
        let existing: [AudioClip]
        let layout: TrackLanes
    }
    private(set) var items: [UUID: Reservation] = [:]
    @Published private(set) var revision: UInt64 = 0
    func reserve(track: Track, clip: AudioClip) {
        var base = track
        base.clips += items.values.filter { $0.track == track.id }.map(\.clip)
        let layout = TrackLanes(track: base)
        var clip = clip
        clip.recordingLane = layout.recordingLane(start: clip.startTime, duration: clip.duration, clips: base.clips)
        items[clip.id] = Reservation(track: track.id, clip: clip, existing: base.clips, layout: layout)
        revision &+= 1
    }
    func update(_ id: UUID, start: Double? = nil, duration: Double? = nil) {
        guard var item = items[id] else { return }
        let oldLane = item.clip.recordingLane
        if let start { item.clip.startTime = start }
        if let duration { item.clip.duration = max(0.01, duration) }
        item.clip.recordingLane = item.layout.recordingLane(start: item.clip.startTime, duration: item.clip.duration, clips: item.existing)
        items[id] = item
        if item.clip.recordingLane != oldLane { revision &+= 1 }
    }
    func remove(_ id: UUID) { items[id] = nil; revision &+= 1 }
    func clear() { items = [:]; revision &+= 1 }
    func count(for track: UUID, existing: Int) -> Int {
        max(existing, items.values.filter { $0.track == track }.map { ($0.clip.recordingLane ?? 0) + 1 }.max() ?? 0)
    }
}
struct RecordingGridOverlay: View {
    let visibleRect: CGRect
    let tracks: [Track]
    let offsets: [CGFloat]
    let heights: [CGFloat]
    let rulerHeight: CGFloat
    let scale: CGFloat
    var alignsToViewport = false
    @ObservedObject private var preview = LiveRecordingPreview.shared
    var body: some View {
        // An idle recorder has no pixels. Keep its subscription, but do not
        // allocate and redraw a viewport canvas on every timeline zoom frame.
        if !preview.takes.isEmpty {
        Canvas { context,size in
            context.translateBy(x: -visibleRect.minX,y: -visibleRect.minY)
            for (id, take) in preview.takes {
                guard let reservation = RecordingLaneLayout.shared.items[id], let index = tracks.firstIndex(where: { $0.id == reservation.track }) else { continue }
                let count = RecordingLaneLayout.shared.count(for: reservation.track, existing: TrackLanes(track: tracks[index]).count)
                let laneHeight = heights[index] / CGFloat(count)
                // Capture buffers can lead the audible transport. Only the drawing
                // is bounded by the same presentation clock as the playhead.
                let duration = min(take.duration, TrackRecording.shared.recordingDisplayPosition.map { max(0, $0 - take.start) } ?? take.duration)
                guard duration > 0 else { continue }
                let rect = CGRect(x: take.start*scale,y: rulerHeight+offsets[index]+CGFloat(reservation.clip.recordingLane ?? 0)*laneHeight+3,width: duration*scale,height: laneHeight-6)
                guard rect.intersects(visibleRect) else { continue }
                let shape = Path(roundedRect: rect, cornerRadius: 3)
                let color = JarasTheme.track(tracks[index], emphasized: false)
                context.fill(shape, with: .linearGradient(Gradient(colors: [color, color.opacity(0.78)]), startPoint: rect.origin, endPoint: CGPoint(x: rect.minX, y: rect.maxY)))
                context.stroke(shape, with: .color(color.opacity(0.75)), lineWidth: 0.6)
                var ink = context
                ink.clip(to: shape)
                let headerHeight: CGFloat = rect.height <= 26 ? rect.height : GridSelectionItem.headerHeight
                ink.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: headerHeight)), with: .color(.black.opacity(0.16)))
                #if !os(macOS)
                if rect.width > 8 {
                    let title = Text(verbatim: reservation.clip.name).font(.jarasSystem(size: 9, weight: .bold)).foregroundColor(.white)
                    ink.draw(title, in: CGRect(x: max(rect.minX, visibleRect.minX) + 4, y: rect.minY + 1, width: max(0, min(rect.maxX, visibleRect.maxX) - max(rect.minX, visibleRect.minX) - 8), height: headerHeight))
                }
                #endif
                guard rect.height > 26 else { continue }
                guard let waveform = take.waveform else { continue }
                let bodyTop = rect.minY + GridSelectionItem.bodyInset
                let channelHeight = max(0, rect.maxY-bodyTop-2)/Double(waveform.channels)
                let rgb = TrackNameContrast.components(tracks[index].color ?? JarasTheme.roleHex(tracks[index].role), emphasized: false)
                let luminance = 0.2126*rgb.red + 0.7152*rgb.green + 0.0722*rgb.blue
                let waveColor = Color(white: luminance > 0.68 ? 0.52 : luminance > 0.42 ? 0.9 : 0.8)
                let step = TimelineAudioWaveform.step(rate: waveform.rate, pixelsPerSecond: scale)
                let span = TimelineAudioWaveform.span(step: step)
                let first = max(0, Int((max(rect.minX,visibleRect.minX)/scale-take.start)*waveform.rate)/span)
                let last = max(first, Int((min(rect.maxX,visibleRect.maxX)/scale-take.start)*waveform.rate)/span)
                for block in first...min(last, first+511) {
                    guard let geometry = waveform.geometry(start: Int64(block*span), step: step, span: span) else { continue }
                    for channel in 0..<min(waveform.channels,geometry.paths.count) {
                        var channelInk = ink
                        let channelRect = CGRect(x: rect.minX, y: bodyTop+channelHeight*Double(channel)+0.5,
                            width: rect.width, height: max(0,channelHeight-1))
                        channelInk.clip(to: Path(channelRect))
                        let middle = bodyTop+channelHeight*(Double(channel)+0.5)
                        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: WaveformAmplitude.fullScale(channelHeight: channelHeight),
                            tx: rect.minX+Double(geometry.start)/waveform.rate*scale, ty: middle)
                        let wave = geometry.paths[channel].applying(transform)
                        if geometry.isPeakEnvelope { channelInk.fill(wave, with: .color(waveColor)) }
                        else { channelInk.stroke(wave,with: .color(waveColor),style: StrokeStyle(
                            lineWidth: TimelineWaveformStrokeStyle.lineWidth(sampleRate: waveform.rate,pixelsPerSecond: scale),
                            lineCap: .round,lineJoin: .round)) }
                    }
                }
                for channel in 0..<waveform.channels {
                    let middle = bodyTop+channelHeight*(Double(channel)+0.5)
                    var center = Path(); center.move(to: CGPoint(x: rect.minX,y: middle)); center.addLine(to: CGPoint(x: rect.maxX,y: middle))
                    ink.stroke(center,with: .color(waveColor.opacity(0.5)),lineWidth: 0.5)
                }
            }
        }.frame(width: visibleRect.width,height: visibleRect.height)
            .offset(x: alignsToViewport ? 0 : visibleRect.minX, y: alignsToViewport ? 0 : visibleRect.minY).allowsHitTesting(false)
        }
    }
}

/// A recording owns a temporary PCM spool plus the same signed 256-frame peaks
/// as the finished waveform. Only visible geometry is materialized; raw samples
/// stay on disk, outside both the audio callback and the main thread.
final class LiveRecordedWaveform: @unchecked Sendable {
    let rate: Double
    let channels: Int
    private let descriptor: Int32
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "live.catlive.recording.waveform", qos: .userInitiated)
    private let cache = NSCache<NSString, TimelineAudioWaveform.Geometry>()
    // Retain the most recent tail while a longer version is prepared.
    private let latest = NSCache<NSString, TimelineAudioWaveform.Geometry>()
    private var pending = Set<String>()
    private var frames: Int64 = 0
    private var peaks: [[SIMD2<Int16>]]
    private var low: [Float], high: [Float]
    private var partial = 0
    init(rate: Double, channels: Int) throws {
        self.rate = rate; self.channels = channels
        peaks = Array(repeating: [], count: channels)
        low = Array(repeating: .infinity, count: channels)
        high = Array(repeating: -.infinity, count: channels)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("catlive-recording-\(UUID().uuidString).pcm")
        descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        // The open descriptor survives unlink; every normal/error exit reclaims
        // the spool automatically, without accumulating temporary recordings.
        Darwin.unlink(url.path)
        cache.totalCostLimit = 16 * 1024 * 1024
        latest.totalCostLimit = 16 * 1024 * 1024
    }
    deinit { Darwin.close(descriptor) }
    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard let input = buffer.floatChannelData, Int(buffer.format.channelCount) == channels else { return }
        let count = Int(buffer.frameLength)
        var pcm = [Float](repeating: 0, count: count * channels)
        for frame in 0..<count { for channel in 0..<channels {
            pcm[frame * channels + channel] = input[channel][frame * buffer.stride]
        } }
        lock.lock(); let start = frames; lock.unlock()
        try pcm.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let result = Darwin.pwrite(descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written,
                    off_t(start * Int64(channels * MemoryLayout<Float>.stride) + Int64(written)))
                guard result > 0 else { throw CocoaError(.fileWriteUnknown) }
                written += result
            }
        }
        lock.lock(); defer { lock.unlock() }
        for frame in 0..<count {
            for channel in 0..<channels {
                let raw = pcm[frame * channels + channel], value = raw.isFinite ? raw : 0
                low[channel] = min(low[channel], value); high[channel] = max(high[channel], value)
            }
            partial += 1
            if partial == TimelineAudioWaveform.peakFramesPerInterval {
                for channel in 0..<channels {
                    peaks[channel].append(SIMD2(WaveformPeakCodec.encode(low[channel]), WaveformPeakCodec.encode(high[channel])))
                    low[channel] = .infinity; high[channel] = -.infinity
                }
                partial = 0
            }
        }
        frames += Int64(count)
    }
    func geometry(start: Int64, step: Int, span: Int) -> TimelineAudioWaveform.Geometry? {
        lock.lock(); let available = min(Int64(span + 1), frames - start); lock.unlock()
        guard available > 0 else { return nil }
        let baseKey = "\(start):\(step):\(span)" as NSString
        let key = "\(start):\(step):\(span):\(available)"
        let previous = latest.object(forKey: baseKey)
        if let existing = cache.object(forKey: key as NSString) { return existing }
        lock.lock()
        guard pending.count < 64, pending.insert(key).inserted else { lock.unlock(); return previous }
        lock.unlock()
        queue.async { [self] in
            defer { lock.lock(); pending.remove(key); lock.unlock() }
            let vertices: TimelineAudioWaveform.VertexBlock
            if step >= TimelineAudioWaveform.peakFramesPerInterval {
                let base = TimelineAudioWaveform.peakFramesPerInterval
                let remaining = min(Int64(span), available)
                let first = Int(start) / base
                let last = Int((start + remaining + Int64(base) - 1) / Int64(base))
                lock.lock()
                let source: [[SIMD2<Int16>]] = (0..<channels).map { channel in
                    var values = Array(peaks[channel][min(first,peaks[channel].count)..<min(last,peaks[channel].count)])
                    if last > peaks[channel].count, partial > 0 {
                        values.append(SIMD2(WaveformPeakCodec.encode(low[channel]), WaveformPeakCodec.encode(high[channel])))
                    }
                    return values
                }
                lock.unlock()
                let points = source.map { values -> [SIMD2<Float>] in
                    var result: [SIMD2<Float>] = []
                    for offset in stride(from: 0, to: values.count, by: step / base) {
                        let group = values[offset..<min(values.count, offset + step / base)]
                        let minimum = group.map(\.x).min() ?? 0, maximum = group.map(\.y).max() ?? 0
                        result.append(SIMD2(Float(offset * base), -WaveformPeakCodec.decode(maximum)))
                        result.append(SIMD2(Float(min(Int(remaining), offset * base + step)), -WaveformPeakCodec.decode(minimum)))
                    }
                    return result
                }
                vertices = TimelineAudioWaveform.VertexBlock(channels: points, start: start, end: start + remaining,
                    step: step, rate: rate, key: key, isPeakEnvelope: true)
            } else {
                var pcm = [Float](repeating: 0, count: Int(available) * channels)
                let ok = pcm.withUnsafeMutableBytes { bytes -> Bool in
                    var read = 0
                    while read < bytes.count {
                        let result = Darwin.pread(descriptor, bytes.baseAddress!.advanced(by: read), bytes.count-read,
                            off_t(start * Int64(channels * MemoryLayout<Float>.stride) + Int64(read)))
                        guard result > 0 else { return false }; read += result
                    }
                    return true
                }
                guard ok else { return }
                let data = (0..<channels).map { channel in (0..<Int(available)).map { pcm[$0 * channels + channel] } }
                vertices = TimelineAudioWaveform.VertexBlock(pcm: TimelineAudioWaveform.PCM(channels: data), start: start,
                    span: span, step: step, rate: rate, key: key).rasterEnvelope
            }
            let geometry = TimelineAudioWaveform.Geometry(vertices: vertices)
            cache.setObject(geometry, forKey: key as NSString, cost: geometry.cost)
            latest.setObject(geometry, forKey: baseKey, cost: geometry.cost)
            Task { @MainActor in LiveRecordingPreview.shared.objectWillChange.send() }
        }
        return previous
    }
}
