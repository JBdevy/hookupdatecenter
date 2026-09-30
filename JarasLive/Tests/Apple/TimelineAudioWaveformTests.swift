import AppKit
import AVFoundation
import SwiftUI

setbuf(stdout, nil)
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("jaras-waveform-\(UUID())", isDirectory: true)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

func waitFor<T>(_ work: () -> T?) -> T {
    let deadline = Date().addingTimeInterval(12)
    while Date() < deadline {
        if let result = work() { return result }
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    fatalError("Waveform did not finish loading")
}

for rate in [44_100.0, 48_000.0] {
    let url = temporary.appendingPathComponent("stereo-\(Int(rate)).wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let length = 131_072
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length))!
    buffer.frameLength = AVAudioFrameCount(length)
    for index in 0..<length {
        buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / rate) * 0.3)
        buffer.floatChannelData![1][index] = index == 12_345 ? -0.9 : 0
    }
    do {
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
    let cache = TimelineAudioWaveform.shared
    let header = waitFor { cache.header(url) }
    precondition(header.rate == rate && header.frames == length && header.channels == 2)
    let close = waitFor { cache.geometry(url, header: header, block: 0, pixelsPerSecond: rate * 2) }
    var moves = 0, lines = 0
    close.paths[0].forEach { element in
        switch element {
        case .move(to: let point):
            moves += 1
            precondition(point == .zero)
        case .line(to: let point):
            lines += 1
            let index = Int((point.x * rate).rounded())
            precondition(abs(point.y + CGFloat(buffer.floatChannelData![0][index])) < 0.000001, "line must retain signed PCM samples")
        default: fatalError("sample waveform must not contain disconnected bars")
        }
    }
    precondition(moves == 1 && lines == 512)
    let transition = cache.drawing(url, header: header, start: 0, end: 512 / rate, pixelsPerSecond: rate / 4)
    precondition(!transition.values.isEmpty, "changing detail level retains a ready waveform while decoding the next level")
    precondition(close === cache.geometry(url, header: header, block: 0, pixelsPerSecond: rate * 2), "warm drawing reuses geometry")
    let next = waitFor { cache.geometry(url, header: header, block: 1, pixelsPerSecond: rate * 2) }
    precondition(next.start == 512)
    var endY: CGFloat = 0, startY: CGFloat = 0
    close.paths[0].forEach { if case .line(to: let point) = $0 { endY = point.y } }
    next.paths[0].forEach { if case .move(to: let point) = $0 { startY = point.y } }
    precondition(endY == startY, "neighboring sample blocks join without a seam")
    let far = waitFor { cache.geometry(url, header: header, block: 0, pixelsPerSecond: rate / 1024) }
    precondition(far.paths.count == 3)
    precondition(abs(far.paths[1].boundingRect.maxY - 0.9) < 0.000001, "short negative transient must survive far zoom")
    var closed = false
    far.paths[0].forEach { if case .closeSubpath = $0 { closed = true } }
    precondition(!closed, "far zoom retains the same signed curve, without switching to an envelope")
    let persistentURL = url.deletingLastPathComponent().appendingPathComponent("WF").appendingPathComponent(url.lastPathComponent + ".waveform")
    let persistentData = try Data(contentsOf: persistentURL)
    let reopened = TimelineAudioWaveform()
    let reopenedHeader = waitFor { reopened.header(url) }
    let restored = waitFor { reopened.geometry(url, header: reopenedHeader, block: 0, pixelsPerSecond: rate / 1024) }
    precondition(restored.paths == far.paths, "a new waveform cache reproduces the exact signed curve from the disk cache")
    let persistedAgain = try Data(contentsOf: persistentURL)
    precondition(persistedAgain == persistentData, "reopening uses the existing waveform file")
    let distant = reopened.drawing(url, header: reopenedHeader, start: 0, end: Double(length) / rate, pixelsPerSecond: 0.1647805478659852)
    precondition(!distant.values.isEmpty && !distant.paths.isEmpty, "a large zoom keeps the full-file waveform while new detail loads")
    print("PERSISTENT_WF_REOPEN_AND_FULL_FILE_ZOOM_FALLBACK_OK rate=\(rate)")
    print("REAL_PCM_SIGNED_STEREO_CURVE_TRANSIENT_CACHE_AND_BLOCK_SEAMS_OK rate=\(rate)")

    // Every coarser level keeps real samples at their original time, even
    // across the streamed decoder's buffer boundaries and large zoom changes.
    for step in [2, 4, 16, 64, 256, 512, 1024, 2048, 16_384] {
        let scale = rate / Double(step * 2)
        let span = TimelineAudioWaveform.span(step: step)
        let geometry = waitFor { cache.geometry(url, header: header, block: 12_345 / span, pixelsPerSecond: scale) }
        var impulse = false
        for channel in 0..<2 {
            var previous = -1
            geometry.paths[channel].forEach { element in
                let point: CGPoint
                switch element {
                case .move(to: let p), .line(to: let p): point = p
                default: fatalError("zoom levels must all draw one continuous, time-ordered line")
                }
                let frame = Int(geometry.start) + Int((point.x * rate).rounded())
                precondition(frame > previous && frame < length)
                previous = frame
                precondition(abs(point.y + CGFloat(buffer.floatChannelData![channel][frame])) < 0.000001, "zoom cannot invent or reposition waveform points")
                if channel == 1 && point.y > 0.8 { precondition(frame == 12_345); impulse = true }
            }
        }
        precondition(impulse, "a one-sample transient must remain at exactly the same source position at every zoom")
    }
    print("WAVEFORM_ALL_DETAIL_LEVELS_PRESERVE_REAL_SAMPLE_TIMES_AND_TRANSIENTS_OK")

    // Reproduce a zoom-out where new outer blocks arrive before the center.
    // The already visible center must remain drawn during partial replacement.
    let worker = DispatchQueue(label: "jaras.waveform.transition-fixture")
    let transitionCache = TimelineAudioWaveform(worker: worker)
    let transitionHeader = waitFor { transitionCache.header(url) }
    for block in 0...1 { _ = waitFor { transitionCache.geometry(url, header: transitionHeader, block: block, pixelsPerSecond: rate * 2) } }
    let oldDrawing = transitionCache.drawing(url, header: transitionHeader, start: 0, end: 1024 / rate, pixelsPerSecond: rate * 2)
    precondition(oldDrawing.values.count == 2)
    _ = waitFor { transitionCache.geometry(url, header: transitionHeader, block: 2, pixelsPerSecond: rate / 4) }
    worker.suspend()
    let partial = transitionCache.drawing(url, header: transitionHeader, start: 0, end: 1536 / rate, pixelsPerSecond: rate / 4)
    let keepsCenter = partial.values.contains { $0.start <= 700 && $0.end > 700 }
    worker.resume()
    precondition(keepsCenter, "partial arrival of a new detail level must not erase previously visible audio")
    let complete: TimelineAudioWaveform.Drawing = waitFor {
        let drawing = transitionCache.drawing(url, header: transitionHeader, start: 0, end: 1536 / rate, pixelsPerSecond: rate / 4)
        return drawing.step == 2 && drawing.values.count == 3 ? drawing : nil
    }
    precondition(complete.step == 2)
    let repeatedComplete = transitionCache.drawing(url, header: transitionHeader, start: 0, end: 1536 / rate, pixelsPerSecond: rate / 4 * 0.9999)
    precondition(complete.cgPaths.count == repeatedComplete.cgPaths.count)
    precondition(zip(complete.cgPaths, repeatedComplete.cgPaths).allSatisfy { $0 === $1 }, "successive zoom frames within a detail level must reuse the immutable display paths")
    var joinedMoves = 0
    complete.paths[0].forEach { if case .move = $0 { joinedMoves += 1 } }
    precondition(joinedMoves == 1, "adjacent cache blocks form one curve without repeated stroke caps")
    print("WAVEFORM_PARTIAL_DETAIL_TRANSITION_RETAINS_VISIBLE_CENTER_OK")
    // Zooming within one resolution changes the visible source boundaries.
    // A complete, slightly wider curve can serve those intervals unchanged.
    let covered = transitionCache.drawing(url, header: transitionHeader, start: 512 / rate, end: 1024 / rate, pixelsPerSecond: rate / 4 * 0.9999)
    precondition(covered.step == complete.step && covered.origin == complete.origin)
    precondition(zip(complete.cgPaths, covered.cgPaths).allSatisfy { $0 === $1 }, "same-detail zoom must reuse a complete curve that covers its source interval")
    let outside: TimelineAudioWaveform.Drawing = waitFor {
        let value = transitionCache.drawing(url, header: transitionHeader, start: 2048 / rate, end: 2560 / rate, pixelsPerSecond: rate / 4)
        return value.step == 2 && value.values.contains { $0.start <= 2048 && $0.end >= 2560 } ? value : nil
    }
    precondition(!zip(complete.cgPaths, outside.cgPaths).allSatisfy { $0 === $1 }, "a disjoint interval must request its own audio blocks")
    print("WAVEFORM_SAME_DETAIL_COVERAGE_REUSES_PATH_AND_EXCLUDES_DISJOINT_AUDIO_OK")


    // Capture the actual timeline drawing helper without touching the user project.
    @MainActor func render(scale: Double, start: Double, name: String, base: Double = 0, loopLength: Double? = nil) -> NSBitmapImageRep {
        let width = 720.0, height = 200.0
        var clip = AudioClip(startTime: base, duration: Double(length) / rate, sourceOffset: 0, playbackRate: 1, gain: 1)
        clip.loopLength = loopLength
        let tile = CGRect(x: (base + start) * scale, y: 0, width: width, height: height)
        let step = TimelineAudioWaveform.step(rate: rate, pixelsPerSecond: scale)
        let span = TimelineAudioWaveform.span(step: step)
        let first = max(0, Int(start * rate) / span)
        let last = min(length - 1, Int((start + width / scale) * rate)) / span
        for block in first...last {
            let geometry = waitFor { cache.geometry(url, header: header, block: block, pixelsPerSecond: scale) }
        }
        if let loopLength, loopLength * scale < 1 {
            let loopScale = 128 / loopLength
            let span = TimelineAudioWaveform.span(step: TimelineAudioWaveform.step(rate: rate, pixelsPerSecond: loopScale))
            for block in 0...Int(loopLength * rate) / span { _ = waitFor { cache.geometry(url, header: header, block: block, pixelsPerSecond: loopScale) } }
        }
        let canvas = Canvas { context, _ in
            context.fill(Path(CGRect(x: 0, y: 0, width: width, height: height)), with: .color(.green))
            context.translateBy(x: -tile.minX, y: 0)
            drawTimelineAudioWaveform(clip, url: url, rect: CGRect(x: base * scale, y: 0, width: clip.duration * scale, height: height), waveTop: 14, scale: scale, tile: tile, silenced: false, context: &context)
        }.frame(width: width, height: height)
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = 1
        guard let cg = renderer.cgImage else { fatalError("Missing waveform image") }
        let image = NSBitmapImageRep(cgImage: cg)
        let data = image.representation(using: .png, properties: [:])!
        try! data.write(to: URL(fileURLWithPath: "/tmp/jaras-real-waveform-\(name)-\(Int(rate)).png"))
        return image
    }
    MainActor.assumeIsolated {
        let closeImage = render(scale: rate * 2, start: 0, name: "close")
        let distantImage = render(scale: rate * 2, start: 0, name: "distant", base: 10_000)
        precondition(closeImage.bytesPerRow == distantImage.bytesPerRow)
        let bytes = closeImage.bytesPerRow * closeImage.pixelsHigh
        let a = closeImage.bitmapData!, b = distantImage.bitmapData!
        let difference = (0..<bytes).map { abs(Int(a[$0]) - Int(b[$0])) }.max()!
        print("LARGE_COORDINATE_WAVEFORM_MAX_PIXEL_DELTA=\(difference)")
        precondition(difference <= 3, "large timeline coordinates must not distort the waveform")
        for divisor in [4.0, 16, 64, 256, 1024] {
            let boundary = rate / divisor
            let before = render(scale: boundary * 1.000001, start: 0, name: "level-before")
            let after = render(scale: boundary * 0.999999, start: 0, name: "level-after")
            let count = before.bytesPerRow * before.pixelsHigh
            let a = before.bitmapData!, b = after.bitmapData!
            let difference = (0..<count).reduce(0.0) { $0 + Double(abs(Int(a[$1]) - Int(b[$1]))) } / Double(count * 255)
            print("WAVEFORM_DETAIL_BOUNDARY_MEAN_PIXEL_DELTA=\(difference) divisor=\(divisor)")
            precondition(difference < 0.015, "crossing a detail threshold must not visibly replace the waveform shape")
        }
        let farImage = render(scale: 240, start: 0, name: "far")
        let coverage = (10..<min(700, Int(Double(length) / rate * 240) - 10)).map { farImage.colorAt(x: $0, y: 45)!.usingColorSpace(.deviceRGB)!.greenComponent }
        let seamDifference = coverage.max()! - coverage.min()!
        print("WAVEFORM_VECTOR_TILE_SEAM_DELTA=\(seamDifference)")
        precondition(seamDifference < 0.02, "cached waveform blocks must not leave pale vertical seams")
        let loop = render(scale: 240, start: 0, name: "loop", loopLength: 0.25)
        precondition(loop.colorAt(x: 300, y: 60)!.usingColorSpace(.deviceRGB)!.greenComponent < 0.5, "repeated source waveform covers later loop periods")
        let collapsed = render(scale: 30, start: 0, name: "collapsed-loop", loopLength: 0.01)
        precondition(collapsed.colorAt(x: 60, y: 60)!.usingColorSpace(.deviceRGB)!.greenComponent < 0.5, "subpixel repeats retain a continuous waveform")
    }
}
print("REAL_WAVEFORM_DRAWING_FIXTURES_CAPTURED")

// Silent plateaus keep their endpoints and every transient, without thousands
// of redundant horizontal stroke joins. Separate source intervals stay apart.
let plateauPCM = TimelineAudioWaveform.PCM(channels: [[0, 0, 0, 1, 0, 0, 0]])
let plateau = TimelineAudioWaveform.Geometry(pcm: plateauPCM, start: 0, rate: 1, step: 1, span: 6)
let separatedPlateau = TimelineAudioWaveform.Geometry(pcm: plateauPCM, start: 12, rate: 1, step: 1, span: 6)
let plateauDrawing = TimelineAudioWaveform.Drawing(values: [plateau, separatedPlateau], step: 1)
var plateauPoints: [CGPoint] = [], plateauMoves = 0
plateauDrawing.paths[0].forEach {
    switch $0 {
    case .move(to: let point): plateauMoves += 1; plateauPoints.append(point)
    case .line(to: let point): plateauPoints.append(point)
    default: preconditionFailure("a waveform is an open sample curve")
    }
}
precondition(plateauMoves == 2, "separate audio intervals must never gain a connecting line")
precondition(plateauPoints == [CGPoint(x: 0, y: 0), CGPoint(x: 2, y: 0), CGPoint(x: 3, y: -1), CGPoint(x: 4, y: 0), CGPoint(x: 6, y: 0), CGPoint(x: 12, y: 0), CGPoint(x: 14, y: 0), CGPoint(x: 15, y: -1), CGPoint(x: 16, y: 0), CGPoint(x: 18, y: 0)], "horizontal-run reduction must preserve exact onset, transient, endpoint and gap positions")
print("HORIZONTAL_WAVEFORM_RUNS_PRESERVE_TRANSIENTS_ENDPOINTS_AND_GAPS_OK")

let recordingURL = temporary.appendingPathComponent("recording.wav")
let mono = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
func writeRecording(frames: Int, sample: Float) throws {
    let buffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    for index in 0..<frames { buffer.floatChannelData![0][index] = sample }
    let file = try AVAudioFile(forWriting: recordingURL, settings: mono.settings)
    try file.write(from: buffer)
}
try writeRecording(frames: 512, sample: 0.1)
let cache = TimelineAudioWaveform.shared
let before = waitFor { cache.header(recordingURL) }
let beforeGeometry = waitFor { cache.geometry(recordingURL, header: before, block: 0, pixelsPerSecond: 88_200) }
RunLoop.main.run(until: Date().addingTimeInterval(1.05))
try writeRecording(frames: 1024, sample: 0.6)
let after: TimelineAudioWaveform.Header = waitFor {
    guard let header = cache.header(recordingURL, refresh: true), header.frames == 1024 else { return nil }
    return header
}
let afterGeometry = waitFor { cache.geometry(recordingURL, header: after, block: 0, pixelsPerSecond: 88_200) }
precondition(after.channels == 1 && beforeGeometry !== afterGeometry)
precondition(abs(afterGeometry.paths[0].boundingRect.minY + 0.6) < 0.000001, "recording growth must not keep stale decoded samples")
print("MONO_RECORDING_GROWTH_REFRESH_AND_PCM_INVALIDATION_OK")

let cancellation = TimelineAudioWaveform.Geometry(pcm: TimelineAudioWaveform.PCM(channels: [[0.5, -0.25, 0.75], [-0.5, 0.25, -0.75]]), start: 0, rate: 48000, step: 1, span: 3)
precondition(cancellation.paths.count == 3)
cancellation.paths[2].forEach { element in
    switch element {
    case .move(to: let point), .line(to: let point): precondition(point.y == 0, "Mono L-R must mix PCM before computing its waveform")
    default: break
    }
}
print("MONO_LR_WAVEFORM_PHASE_CANCELLATION_OK")
