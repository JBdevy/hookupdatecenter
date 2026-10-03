import Foundation
import Metal
import QuartzCore

setbuf(stdout, nil)
guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal device required for GPU waveform validation") }
let engine = MetalWaveformEngine(device: device, synchronousPreparation: true)
precondition(engine.isReady, engine.preparationError ?? "Metal pipeline unavailable")
let size = CGSize(width: 128, height: 128)
let item = CGRect(x: 10, y: 10, width: 108, height: 108)
let block = TimelineAudioWaveform.VertexBlock(
    channels: [[SIMD2(0, 0), SIMD2(16, -0.75), SIMD2(32, 0), SIMD2(48, 0.75), SIMD2(64, 0)],
               [SIMD2(0, 0.5), SIMD2(16, 0.5), SIMD2(32, 0.5), SIMD2(48, 0.5), SIMD2(64, 0.5)]],
    start: 96_000, end: 96_065, step: 1, rate: 48_000, key: "actual-pcm-test")
let unit = TimelineAudioWaveform.VertexBlock(channels: [[SIMD2(0, 0), SIMD2(1, 0)]],
    start: 0, end: 1, step: 1, rate: 1, key: "unit-segment")
var retained: [String: MetalWaveformEngine.SourceBuffer] = [:]

struct Pixels {
    let bytes: [UInt8]
    let width: Int
    let height: Int
    func alpha(_ x: Int, _ y: Int) -> Int { Int(bytes[(y * width + x) * 4 + 3]) }
    func maximumAlpha(_ x: Int, _ y: Int, radius: Int = 1) -> Int {
        var maximum = 0
        for row in max(0, y - radius)...min(height - 1, y + radius) {
            for column in max(0, x - radius)...min(width - 1, x + radius) { maximum = max(maximum, alpha(column, row)) }
        }
        return maximum
    }
}

func render(_ strokes: [MetalWaveformStroke], density: Float = 1) -> Pixels {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
        width: Int(size.width * CGFloat(density)), height: Int(size.height * CGFloat(density)), mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    let texture = device.makeTexture(descriptor: descriptor)!
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
    let command = engine.commandQueue!.makeCommandBuffer()!
    precondition(engine.encode(MetalWaveformFrame(size: size, strokes: strokes), pass: pass,
        command: command, density: density, retaining: &retained))
    command.commit()
    command.waitUntilCompleted() // Test readback only; never used in application drawing.
    precondition(command.status == .completed, String(describing: command.error))
    var pixels = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
    texture.getBytes(&pixels, bytesPerRow: texture.width * 4,
        from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
    return Pixels(bytes: pixels, width: texture.width, height: texture.height)
}

func waveform(scale: SIMD2<Float> = SIMD2(1, 32), translation: SIMD2<Float> = SIMD2(20, 50), channel: Int = 0,
              clip: CGRect = item, colour: SIMD4<Float> = SIMD4(0.7, 0.7, 0.7, 0.8)) -> MetalWaveformStroke {
    MetalWaveformStroke(block: block, channel: channel, scale: scale, translation: translation,
        clip: clip, color: colour, itemRect: item)
}
let original = render([waveform()])
precondition(original.maximumAlpha(36, 26) > 180 && original.maximumAlpha(68, 74) > 180)
precondition(original.maximumAlpha(36, 50) == 0, "do not replace actual samples by a synthetic centerline")
let uploads = engine.uploadedBufferCount
let shifted = render([waveform(translation: SIMD2(25, 53))])
precondition(shifted.maximumAlpha(41, 29) > 180)
precondition(engine.uploadedBufferCount == uploads, "pan/zoom must reuse immutable MTLBuffers")
let amplified = render([waveform(scale: SIMD2(1, 48))])
precondition(amplified.maximumAlpha(36, 14) > 180 && amplified.maximumAlpha(68, 86) > 180)
precondition(amplified.maximumAlpha(36, 26) == 0, "positive item gain must change displayed amplitude")
let duplicate = render([waveform(), waveform(), waveform()])
precondition(duplicate.bytes == original.bytes, "overlapping joins/duplicates must not accumulate alpha or darken peaks")
print("METAL_ACTUAL_VERTICES_TRANSFORM_GAIN_AND_MAX_COVERAGE_OK")

let stereo = render([waveform(), waveform(translation: SIMD2(20, 80), channel: 1)])
precondition(stereo.maximumAlpha(36, 26) > 180 && stereo.maximumAlpha(50, 96) > 180)
precondition(engine.uploadedBufferCount == uploads + 1, "channels share source identity with independent immutable buffers")
let clipped = render([waveform(clip: CGRect(x: 42, y: 10, width: 20, height: 100))])
for y in 0..<128 {
    for x in 0..<128 where x < 42 || x >= 62 { precondition(clipped.alpha(x, y) == 0) }
}
precondition(clipped.maximumAlpha(52, 50) > 180)
let empty = render([waveform(clip: CGRect(x: 140, y: 0, width: 40, height: 40))])
precondition(empty.bytes.allSatisfy { $0 == 0 } && engine.lastEncodedStrokeCount == 0)
let retina = render([waveform()], density: 2)
precondition(retina.maximumAlpha(72, 52, radius: 2) > 180)
precondition(retina.bytes.contains { $0 > 0 && $0 < 180 }, "Retina edges must be antialiased")
print("METAL_CHANNELS_PIXEL_CLIPPING_CULLING_AND_RETINA_OK")

var notch = MetalWaveformStroke(block: unit, channel: 0, scale: SIMD2(100, 1), translation: SIMD2(10, 57),
    clip: CGRect(x: 10, y: 10, width: 100, height: 50), color: SIMD4(1, 1, 1, 1),
    itemRect: CGRect(x: 10, y: 10, width: 100, height: 50), firstSeamX: 50, repeatSpacing: 40,
    lineWidth: 20, itemCornerRadius: 8)
let notched = render([notch])
precondition(notched.alpha(50, 58) == 0 && notched.alpha(48, 53) > 200 && notched.alpha(60, 58) > 200)
notch = MetalWaveformStroke(block: unit, channel: 0, scale: SIMD2(100, 1), translation: SIMD2(10, 12),
    clip: CGRect(x: 10, y: 10, width: 100, height: 50), color: SIMD4(1, 1, 1, 1),
    itemRect: CGRect(x: 10, y: 10, width: 100, height: 50), firstSeamX: 50, repeatSpacing: 40,
    lineWidth: 20, itemCornerRadius: 8)
let top = render([notch])
precondition(top.alpha(10, 10) == 0 && top.alpha(20, 11) > 200 && top.alpha(50, 11) > 200,
    "round item corners must clip; repetition notch belongs only to the bottom edge")
print("METAL_ROUNDED_ITEM_AND_FIXED_BOTTOM_REPETITION_NOTCH_OK")

let peakBlock = TimelineAudioWaveform.VertexBlock(channels: [
    [SIMD2(0, -0.75), SIMD2(64, 0.5), SIMD2(64, -0.25), SIMD2(128, 0.25)]
], start: 0, end: 128, step: 64, rate: 48_000, key: "interval-peak-test", isPeakEnvelope: true)
func peakStroke(clip: CGRect = item, block: TimelineAudioWaveform.VertexBlock = peakBlock) -> MetalWaveformStroke {
    MetalWaveformStroke(block: block, channel: 0, scale: SIMD2(1, 32), translation: SIMD2(0, 64),
        clip: clip, color: SIMD4(repeating: 1), itemRect: item)
}
let peaks = render([peakStroke()])
precondition(peaks.alpha(20, 41) > 240 && peaks.alpha(60, 75) > 240 && peaks.alpha(80, 57) > 240)
precondition(peaks.alpha(80, 45) == 0, "a later interval must preserve its own smaller extrema")
precondition(peaks.alpha(32, 41) > 240 && peaks.alpha(60, 42) == 0, "real peak remains at center while neighboring bins join with a sloped contour")
let trimmedPeak = render([peakStroke(clip: CGRect(x: 34, y: 10, width: 3, height: 108))])
precondition(trimmedPeak.alpha(35, 41) > 240 && trimmedPeak.alpha(35, 78) > 240,
             "a trim inside one bucket must retain its continuous peak contour")
precondition(trimmedPeak.alpha(33, 64) == 0 && trimmedPeak.alpha(37, 64) == 0)
let equalPeaks = TimelineAudioWaveform.VertexBlock(channels: [
    [SIMD2(0, -0.5), SIMD2(64.5, 0.5), SIMD2(64.5, -0.5), SIMD2(128, 0.5)]
], start: 0, end: 128, step: 64, rate: 48_000, key: "equal-intervals", isPeakEnvelope: true)
let seamless = render([peakStroke(block: equalPeaks)])
precondition(seamless.alpha(64, 64) == 255 && seamless.alpha(65, 64) == 255,
             "adjacent envelopes must meet without transparent vertical seams")
let subpixelPeak = TimelineAudioWaveform.VertexBlock(channels: [[SIMD2(20.05, -0.5), SIMD2(20.3, 0.5)]],
    start: 0, end: 128, step: 1, rate: 48_000, key: "subpixel-interval", isPeakEnvelope: true)
let tinyPeak = render([peakStroke(block: subpixelPeak)])
precondition(tinyPeak.alpha(20, 50) > 240, "an interval below one pixel must preserve its visible peak")
let silentPeak = TimelineAudioWaveform.VertexBlock(channels: [[SIMD2(0, 0), SIMD2(128, 0)]],
    start: 0, end: 128, step: 128, rate: 48_000, key: "silent-interval", isPeakEnvelope: true)
let quiet = render([peakStroke(block: silentPeak)], density: 2)
precondition(quiet.maximumAlpha(80, 128) > 100 && quiet.maximumAlpha(80, 132) == 0,
             "phase-cancelled silence keeps only a one-device-pixel centerline")
print("METAL_PEAK_INTERVALS_SUBBUCKET_TRIMS_SEAMLESS_JOINS_AND_SUBPIXEL_PEAKS_OK")

let manyPoints = TimelineAudioWaveform.VertexBlock(channels: [(0..<100_000).map { SIMD2(Float($0), sin(Float($0) * 0.01)) }],
    start: 0, end: 100_000, step: 1, rate: 48_000, key: "large-culled-source")
let narrow = MetalWaveformStroke(block: manyPoints, channel: 0, scale: SIMD2(1, 10), translation: SIMD2(-50_000, 64),
    clip: CGRect(x: 30, y: 0, width: 32, height: 128), color: SIMD4(1, 1, 1, 1), itemRect: CGRect(origin: .zero, size: size))
_ = render([narrow])
precondition(engine.lastEncodedStrokeCount == 1 && engine.lastEncodedSegmentCount < 40,
    "a partly visible 100k point block must submit only visible segments in one draw")
print("METAL_VISIBLE_SOURCE_RANGE_BATCHING_OK segments=\(engine.lastEncodedSegmentCount)")

let outside = TimelineAudioWaveform.VertexBlock(channels: [[SIMD2(0, 0), SIMD2(1, 0)]],
    start: 0, end: 2, step: 1, rate: 1, key: "outside-source-range")
let beforeCulling = engine.uploadedBufferCount
_ = render([MetalWaveformStroke(block: outside, channel: 0, scale: SIMD2(1, 1), translation: SIMD2(200, 64),
    clip: item, color: SIMD4(repeating: 1), itemRect: item)])
precondition(engine.uploadedBufferCount == beforeCulling && engine.lastEncodedStrokeCount == 0,
             "a visible clip rectangle must not upload a source range lying wholly outside that rectangle")

// Model transient GPU memory pressure deterministically without exhausting the
// machine. A failed pass remains uncommitted and retains the previous resources.
var allowAllocation = true
let pressureEngine = MetalWaveformEngine(device: device, synchronousPreparation: true) { bytes, count in
    allowAllocation ? device.makeBuffer(bytes: bytes, length: count, options: .storageModeShared) : nil
}
let pressureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 128, height: 128, mipmapped: false)
pressureDescriptor.usage = .renderTarget
let pressurePass = MTLRenderPassDescriptor()
pressurePass.colorAttachments[0].texture = device.makeTexture(descriptor: pressureDescriptor)!
pressurePass.colorAttachments[0].loadAction = .clear
pressurePass.colorAttachments[0].storeAction = .store
var pressureRetained: [String: MetalWaveformEngine.SourceBuffer] = [:]
let firstPressureCommand = pressureEngine.commandQueue!.makeCommandBuffer()!
precondition(pressureEngine.encode(MetalWaveformFrame(size: size, strokes: [waveform()]), pass: pressurePass,
    command: firstPressureCommand, density: 1, retaining: &pressureRetained))
firstPressureCommand.commit(); firstPressureCommand.waitUntilCompleted()
let previousBuffers = pressureRetained
allowAllocation = false
let failedCommand = pressureEngine.commandQueue!.makeCommandBuffer()!
let pendingPressureFrame = MetalWaveformFrame(size: size, strokes: [waveform(), waveform(channel: 1)])
precondition(!pressureEngine.encode(pendingPressureFrame, pass: pressurePass,
    command: failedCommand, density: 1, retaining: &pressureRetained),
    "an unavailable buffer must reject the whole frame instead of clearing missing waveforms")
precondition(failedCommand.status == .notEnqueued && pressureRetained.count == previousBuffers.count &&
    previousBuffers.allSatisfy { pressureRetained[$0.key] === $0.value })
allowAllocation = true
let recoveredCommand = pressureEngine.commandQueue!.makeCommandBuffer()!
precondition(pressureEngine.encode(pendingPressureFrame, pass: pressurePass,
    command: recoveredCommand, density: 1, retaining: &pressureRetained))
recoveredCommand.commit(); recoveredCommand.waitUntilCompleted()
precondition(recoveredCommand.status == .completed && pressureRetained.count == 2)
print("METAL_CULLS_BEFORE_UPLOAD_AND_PRESERVES_COMPLETE_FRAME_UNDER_MEMORY_PRESSURE_OK")

// Warm repeated transforms must never allocate another source GPU buffer.
let beforeStress = engine.uploadedBufferCount
for index in 0..<40 {
    _ = render([waveform(scale: SIMD2(Float(index) * 0.005 + 1, 32), translation: SIMD2(20, 50))])
}
precondition(engine.uploadedBufferCount == beforeStress)
print("METAL_REPEATED_ZOOM_BUFFER_REUSE_OK device=\(device.name)")

// Measure the actual command path for 200 visible strokes, including the same
// queue-scheduling fence used by the view. Completion waits are for measurement
// isolation/readback in this test only, and are excluded from encode timing.
let benchmarkSize = CGSize(width: 2200, height: 1200)
let benchmarkTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
    width: 2200, height: 1200, mipmapped: false)
benchmarkTextureDescriptor.usage = .renderTarget
benchmarkTextureDescriptor.storageMode = .private
let benchmarkTexture = device.makeTexture(descriptor: benchmarkTextureDescriptor)!
let benchmarkBlock = TimelineAudioWaveform.VertexBlock(channels: [(0..<4096).map {
    SIMD2(Float($0), sin(Float($0) * 0.17) * sin(Float($0) * 0.003))
}], start: 0, end: 4096, step: 1, rate: 48_000, key: "200-visible-strokes")
func measureBatch(_ benchmarkBlock: TimelineAudioWaveform.VertexBlock, label: String) {
var encodeTimes: [Double] = [], scheduleTimes: [Double] = [], gpuTimes: [Double] = []
for frameIndex in 0..<16 {
    var strokes: [MetalWaveformStroke] = []
    for row in 0..<20 {
        for column in 0..<10 {
            let rect = CGRect(x: column * 220, y: row * 60, width: 218, height: 58)
            strokes.append(MetalWaveformStroke(block: benchmarkBlock, channel: 0,
                scale: SIMD2(0.053 + Float(frameIndex) * 0.00001, 22),
                translation: SIMD2(Float(rect.minX), Float(rect.midY)), clip: rect,
                color: SIMD4(0.65, 0.65, 0.65, 1), itemRect: rect))
        }
    }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = benchmarkTexture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    let command = engine.commandQueue!.makeCommandBuffer()!
    let started = CACurrentMediaTime()
    precondition(engine.encode(MetalWaveformFrame(size: benchmarkSize, strokes: strokes), pass: pass,
        command: command, density: 1, retaining: &retained))
    let encoded = CACurrentMediaTime()
    command.commit()
    let committed = CACurrentMediaTime()
    command.waitUntilScheduled()
    let scheduled = CACurrentMediaTime()
    command.waitUntilCompleted()
    precondition(command.status == .completed)
    if frameIndex > 0 {
        encodeTimes.append((encoded - started) * 1000)
        scheduleTimes.append((scheduled - committed) * 1000)
        gpuTimes.append((command.gpuEndTime - command.gpuStartTime) * 1000)
    }
}
func percentile(_ values: [Double], _ percent: Double) -> Double {
    values.sorted()[min(values.count - 1, Int(Double(values.count - 1) * percent))]
}
print(String(format: label + " encode_p50_ms=%.3f encode_p95_ms=%.3f schedule_p95_ms=%.3f gpu_p95_ms=%.3f primitives=%d",
    percentile(encodeTimes, 0.5), percentile(encodeTimes, 0.95), percentile(scheduleTimes, 0.95),
    percentile(gpuTimes, 0.95), engine.lastEncodedSegmentCount))
}
measureBatch(benchmarkBlock, label: "METAL_200_STROKES_2200x1200_MEASURED")
var legacyPeakPoints: [SIMD2<Float>] = [], intervalPeakPoints: [SIMD2<Float>] = []
let benchmarkSamples = benchmarkBlock.channels[0]
for start in stride(from: 0, to: benchmarkSamples.count, by: 8) {
    let end = min(benchmarkSamples.count, start + 8)
    let minimum = (start..<end).min { benchmarkSamples[$0].y < benchmarkSamples[$1].y }!
    let maximum = (start..<end).max { benchmarkSamples[$0].y < benchmarkSamples[$1].y }!
    for index in Set([start, minimum, maximum, end - 1]).sorted() { legacyPeakPoints.append(benchmarkSamples[index]) }
    intervalPeakPoints.append(SIMD2(Float(start), benchmarkSamples[minimum].y))
    intervalPeakPoints.append(SIMD2(Float(end), benchmarkSamples[maximum].y))
}
let legacyPeakBlock = TimelineAudioWaveform.VertexBlock(channels: [legacyPeakPoints], start: 0,
    end: 4096, step: 8, rate: 48_000, key: "legacy-four-vertex-peaks")
let intervalPeakBlock = TimelineAudioWaveform.VertexBlock(channels: [intervalPeakPoints], start: 0,
    end: 4096, step: 8, rate: 48_000, key: "two-vertex-peak-intervals", isPeakEnvelope: true)
measureBatch(legacyPeakBlock, label: "METAL_200_LEGACY_PEAK_STROKES_2200x1200_MEASURED")
measureBatch(intervalPeakBlock, label: "METAL_200_INTERVAL_PEAK_STROKES_2200x1200_MEASURED")

#if os(macOS)
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let testWindow = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 128, height: 128),
    styleMask: [.borderless], backing: .buffered, defer: false)
testWindow.isReleasedWhenClosed = false
let surface = MetalWaveformSurface()
surface.frame = NSRect(origin: .zero, size: size)
testWindow.contentView = surface
testWindow.orderBack(nil)
let snapshot = MetalWaveformFrame(size: size, strokes: [waveform()])
surface.submit(snapshot)
let deadline = Date().addingTimeInterval(15)
while surface.submittedFrameCount == 0 && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
}
precondition(surface.submittedFrameCount > 0, "on-demand MTKView must render a supplied snapshot")
RunLoop.main.run(until: Date().addingTimeInterval(0.15))
let idleCount = surface.submittedFrameCount
for _ in 0..<100 { surface.submit(snapshot) }
RunLoop.main.run(until: Date().addingTimeInterval(0.15))
precondition(surface.isPaused && surface.submittedFrameCount == idleCount,
    "idle and unrelated SwiftUI updates must never continuously redraw the waveform")
for index in 0..<30 {
    surface.submit(MetalWaveformFrame(size: size, strokes: [waveform(translation: SIMD2(20 + Float(index) * 0.1, 50))]))
}
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
precondition(surface.submittedFrameCount > idleCount)
let stopped = surface.submittedFrameCount
RunLoop.main.run(until: Date().addingTimeInterval(0.15))
precondition(surface.submittedFrameCount == stopped)
print(String(format: "METAL_ON_DEMAND_IDLE_AND_LATEST_FRAME_COALESCING_OK submitted=%llu coalesced=%llu encode_ms=%.3f schedule_ms=%.3f",
    surface.submittedFrameCount, surface.coalescedFrameCount, surface.lastEncodeMilliseconds, surface.lastScheduleMilliseconds))

func locatedFrame(origin: CGPoint, scale: Double, revision: Int = 1) -> MetalWaveformFrame {
    MetalWaveformFrame(size: size, strokes: [waveform(scale: SIMD2(Float(scale), 32))],
        coordinateSpace: MetalWaveformCoordinateSpace(documentOrigin: origin, pixelsPerSecond: scale, contentRevision: revision))
}
// Zoom redraws vertices into the current viewport. No cached texture may be
// scaled, including large jumps and immediate reversals before the next layout.
let sharedEngine = MetalWaveformEngine.shared
var nativeZoomTimes: [Double] = []
for scale in [1.0, 200.0, 0.1, 80.0, 2.0, 400.0, 1.0] {
    let before = surface.submittedFrameCount
    let begin = CACurrentMediaTime()
    surface.submit(locatedFrame(origin: CGPoint(x: scale * 12, y: 256), scale: scale))
    nativeZoomTimes.append((CACurrentMediaTime() - begin) * 1000)
    precondition(surface.submittedFrameCount == before + 1,
                 "a coordinate change must submit a current-scale vertex frame immediately")
    precondition(surface.presentedContentFrame == CGRect(origin: .zero, size: size),
                 "zoom must never stretch or translate a previous waveform bitmap")
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}
surface.submit(locatedFrame(origin: .zero, scale: 14, revision: 2))
precondition(surface.presentedContentFrame == CGRect(origin: .zero, size: size))
print("METAL_ZOOM_REDRAWS_SOURCE_VERTICES_WITHOUT_TEXTURE_REPROJECTION_OK ms=\(nativeZoomTimes)")

// Read the compositor's actual window pixels. Rendering into an offscreen MTL
// texture alone cannot catch MTKView handing its delegate a previous-size
// drawable after a viewport resize.
func visibleWhitePixels() -> Int? {
    guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
        CGWindowID(testWindow.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else { return nil }
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { raw in
        let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return stride(from: 0, to: bytes.count, by: 4).reduce(0) { count, offset in
        count + (bytes[offset] > 220 && bytes[offset + 1] > 220 && bytes[offset + 2] > 220 ? 1 : 0)
    }
}
let filledInterval = TimelineAudioWaveform.VertexBlock(channels: [[SIMD2<Float>(0, -0.5), SIMD2<Float>(1, 0.5)]],
    start: 0, end: 1, step: 1, rate: 1, key: "resizing-filled-viewport", isPeakEnvelope: true)
func resizedFrame(_ width: CGFloat) -> MetalWaveformFrame {
    let rect = CGRect(x: 0, y: 0, width: width, height: size.height)
    return MetalWaveformFrame(size: rect.size, strokes: [MetalWaveformStroke(block: filledInterval,
        channel: 0, scale: SIMD2(Float(width), 64), translation: SIMD2(0, 64), clip: rect,
        color: SIMD4(repeating: 1), itemRect: rect, itemCornerRadius: 0)],
        coordinateSpace: MetalWaveformCoordinateSpace(documentOrigin: .zero, pixelsPerSecond: 1, contentRevision: 4))
}
testWindow.backgroundColor = .black
surface.submit(resizedFrame(512))
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
if let baseline = visibleWhitePixels(), baseline > 0 {
    var counts: [Int] = [baseline]
    for width: CGFloat in [128, 300, 160, 128, 512, 128] {
        surface.submit(resizedFrame(width))
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        let count = visibleWhitePixels() ?? 0
        counts.append(count)
        precondition(abs(count - baseline) <= max(4, baseline / 100),
                     "resizing a Metal viewport must not clip/blank its displayed waveform: baseline=\(baseline), actual=\(count), width=\(width)")
    }
    print("METAL_NATIVE_DRAWABLE_RESIZE_VISIBLE_PIXEL_COVERAGE_OK pixels=\(counts)")
} else { print("METAL_NATIVE_DRAWABLE_RESIZE_PIXEL_CAPTURE_UNAVAILABLE") }
// Regression for the visible failure: a large zoom jump must not leave any
// waveform pixels before/after the item's current clipping rectangle.
func nativeWhiteBounds() -> CGRect? {
    guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
        CGWindowID(testWindow.windowNumber), [.boundsIgnoreFraming, .bestResolution]) else { return nil }
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { raw in
        let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    var left = image.width, right = -1, top = image.height, bottom = -1
    for y in 0..<image.height { for x in 0..<image.width {
        let i = (y * image.width + x) * 4
        if bytes[i] > 220 && bytes[i + 1] > 220 && bytes[i + 2] > 220 {
            left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
        }
    } }
    guard right >= left else { return .null }
    return CGRect(x: Double(left) / Double(image.width) * 128,
                  y: Double(top) / Double(image.height) * 128,
                  width: Double(right - left + 1) / Double(image.width) * 128,
                  height: Double(bottom - top + 1) / Double(image.height) * 128)
}
let itemClip = CGRect(x: 64, y: 32, width: 32, height: 64)
for zoom in [1.0, 100.0, 0.1, 2800.0, 2.0] {
    surface.submit(MetalWaveformFrame(size: size, strokes: [MetalWaveformStroke(block: filledInterval,
        channel: 0, scale: SIMD2(128, 64), translation: SIMD2(0, 64), clip: itemClip,
        color: SIMD4(repeating: 1), itemRect: itemClip, itemCornerRadius: 0)],
        coordinateSpace: MetalWaveformCoordinateSpace(documentOrigin: CGPoint(x: zoom * 10, y: 0),
            pixelsPerSecond: zoom, contentRevision: 8)))
    RunLoop.main.run(until: Date().addingTimeInterval(0.06))
    if let visible = nativeWhiteBounds() {
        precondition(!visible.isNull && visible.width >= 30 && visible.minX >= 63 && visible.maxX <= 97,
                     "zoom must keep the complete sharp waveform inside its current item: \(visible)")
    }
}
print("METAL_NATIVE_HIGH_ZOOM_REVERSALS_STAY_INSIDE_ITEM_PIXEL_BOUNDS_OK")
testWindow.close()
#endif
