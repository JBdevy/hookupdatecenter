import SwiftUI
import MetalKit
import QuartzCore

/// Canvas remains available until asynchronous Metal preparation succeeds, and
/// remains the permanent fallback on a device without a working Metal pipeline.
final class MetalWaveformRenderer: ObservableObject {
    static let shared = MetalWaveformRenderer()
    @Published private(set) var isAvailable = false
    static var isSupported: Bool { shared.isAvailable }
    private init() {
        MetalWaveformEngine.shared.whenReady { [weak self] in self?.isAvailable = true }
    }
}

/// A source block is immutable and shared by every occurrence of an audio file.
/// The transform maps its local sample-frame coordinates into viewport points.
struct MetalWaveformStroke {
    let block: TimelineAudioWaveform.VertexBlock
    let channel: Int
    let scale: SIMD2<Float>
    let translation: SIMD2<Float>
    let clip: CGRect
    let color: SIMD4<Float>
    let itemRect: CGRect
    var firstSeamX: CGFloat? = nil
    var repeatSpacing: CGFloat? = nil
    var lineWidth: Float = 2
    var itemCornerRadius: Float = 3
}

struct MetalWaveformCoordinateSpace: Equatable {
    let documentOrigin: CGPoint
    let pixelsPerSecond: Double
    /// Stable across zoom/pan; changes for item edits or vertical row geometry.
    let contentRevision: Int
}

struct MetalWaveformFrame {
    let size: CGSize
    let strokes: [MetalWaveformStroke]
    var coordinateSpace: MetalWaveformCoordinateSpace? = nil

    func hasSameContent(as other: MetalWaveformFrame) -> Bool {
        coordinateSpace == other.coordinateSpace && size == other.size && strokes.count == other.strokes.count && zip(strokes, other.strokes).allSatisfy { a, b in
            a.block === b.block && a.channel == b.channel && a.scale == b.scale && a.translation == b.translation &&
            a.clip == b.clip && a.color == b.color && a.itemRect == b.itemRect && a.firstSeamX == b.firstSeamX &&
            a.repeatSpacing == b.repeatSpacing && a.lineWidth == b.lineWidth && a.itemCornerRadius == b.itemCornerRadius
        }
    }
}

/// No display link runs here. SwiftUI supplies a new snapshot only when the
/// viewport, gain, colour, or asynchronously prepared source geometry changes.
#if os(macOS)
struct MetalWaveformView: NSViewRepresentable {
    let frame: MetalWaveformFrame
    static var supportsMetal: Bool { MetalWaveformRenderer.isSupported }
    func makeNSView(context: Context) -> MetalWaveformSurface { MetalWaveformSurface() }
    func updateNSView(_ view: MetalWaveformSurface, context: Context) { view.submit(frame) }
}
#else
struct MetalWaveformView: UIViewRepresentable {
    let frame: MetalWaveformFrame
    static var supportsMetal: Bool { MetalWaveformRenderer.isSupported }
    func makeUIView(context: Context) -> MetalWaveformSurface { MetalWaveformSurface() }
    func updateUIView(_ view: MetalWaveformSurface, context: Context) { view.submit(frame) }
}
#endif

#if os(macOS)
typealias MetalWaveformContainerBase = NSView
#else
typealias MetalWaveformContainerBase = UIView
#endif

/// The viewport can move before the GPU has a free drawable. Keep the existing
/// texture in its own child and reproject that child into the newest timeline
/// coordinates immediately. Replacing the drawable and resetting the child
/// happen in the same CA transaction, so old samples never jump to new origins.
final class MetalWaveformSurface: MetalWaveformContainerBase {
    private let renderer = MetalWaveformRenderView()
    private var latest: MetalWaveformFrame?
    private var presented: MetalWaveformFrame?
    var submittedFrameCount: UInt64 { renderer.submittedFrameCount }
    var coalescedFrameCount: UInt64 { renderer.coalescedFrameCount }
    var lastEncodeMilliseconds: Double { renderer.lastEncodeMilliseconds }
    var lastScheduleMilliseconds: Double { renderer.lastScheduleMilliseconds }
    var isPaused: Bool { renderer.isPaused }
    var presentedContentFrame: CGRect { renderer.frame }

    init() {
        super.init(frame: .zero)
        #if os(macOS)
        wantsLayer = true; layer?.masksToBounds = true
        #else
        clipsToBounds = true; isOpaque = false; backgroundColor = .clear; isUserInteractionEnabled = false
        #endif
        addSubview(renderer)
        renderer.didPresent = { [weak self] frame in
            guard let self else { return }
            self.presented = frame
            self.applyPresentationGeometry()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    #if os(macOS)
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); applyPresentationGeometry() }
    #else
    override func layoutSubviews() { super.layoutSubviews(); applyPresentationGeometry() }
    #endif

    func submit(_ frame: MetalWaveformFrame) {
        latest = frame
        applyPresentationGeometry()
        // Layout/gain edits cannot be represented by one texture transform.
        // Submit those immediately instead of ever displaying wrong row data.
        let affine = presented.map { Self.canReproject($0, to: frame) } ?? false
        renderer.submit(frame, allowCoalescing: affine)
    }
    private static func canReproject(_ previous: MetalWaveformFrame, to latest: MetalWaveformFrame) -> Bool {
        guard let old = previous.coordinateSpace, let new = latest.coordinateSpace else { return false }
        return old.contentRevision == new.contentRevision && old.pixelsPerSecond > 0 && new.pixelsPerSecond > 0 &&
            old.pixelsPerSecond.isFinite && new.pixelsPerSecond.isFinite
    }
    static func projectedContentFrame(previous: MetalWaveformFrame, latest: MetalWaveformFrame) -> CGRect {
        guard canReproject(previous, to: latest), let old = previous.coordinateSpace, let new = latest.coordinateSpace else {
            return CGRect(origin: .zero, size: latest.size)
        }
        let ratio = CGFloat(new.pixelsPerSecond / old.pixelsPerSecond)
        return CGRect(x: old.documentOrigin.x * ratio - new.documentOrigin.x,
                      y: old.documentOrigin.y - new.documentOrigin.y,
                      width: previous.size.width * ratio, height: previous.size.height)
    }
    private func applyPresentationGeometry() {
        guard let latest else { return }
        let rect = presented.map { Self.projectedContentFrame(previous: $0, latest: latest) } ?? CGRect(origin: .zero, size: latest.size)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if renderer.frame != rect { renderer.frame = rect }
        CATransaction.commit()
    }
}

/// At most two command buffers are in flight. Superseded snapshots are replaced,
/// rather than queued behind a zoom gesture. Drawable presentation participates
/// in the same Core Animation transaction as item/ruler geometry.
private final class MetalWaveformRenderView: MTKView, MTKViewDelegate {
    var didPresent: ((MetalWaveformFrame) -> Void)?
    private var lastPresentedSequence: UInt64 = 0
    private struct ScheduledPresentation {
        let frame: MetalWaveformFrame
        let drawable: CAMetalDrawable
        let lease: FrameLease
        let requestedAt: Double
    }
    private var scheduledPresentations: [UInt64: ScheduledPresentation] = [:]
    private var requiresImmediateSubmission = false
    private let engine = MetalWaveformEngine.shared
    private var latestFrame: MetalWaveformFrame?
    private var pending: MetalWaveformFrame?
    private var visibleBuffers: [String: MetalWaveformEngine.SourceBuffer] = [:]
    private let flights = FrameGate()
    private var rendering = false
    private var drawableRetryUsed = false
    private(set) var submittedFrameCount: UInt64 = 0
    private(set) var coalescedFrameCount: UInt64 = 0
    private(set) var lastEncodeMilliseconds: Double = 0
    private(set) var lastScheduleMilliseconds: Double = 0

    private final class FrameGate {
        private let lock = NSLock()
        private var count = 0
        var hasCapacity: Bool { lock.lock(); defer { lock.unlock() }; return count < 2 }
        func begin(ignoringLimit: Bool = false) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard ignoringLimit || count < 2 else { return false }
            count += 1
            return true
        }
        func end() { lock.lock(); count -= 1; lock.unlock() }
    }

    /// A drawable remains occupied until both GPU completion and presentation.
    /// Completing on the GPU alone must not release a slot while its scheduled
    /// presentation is still waiting for the main run loop.
    private final class FrameLease {
        private let lock = NSLock()
        private var state = 0
        private let release: () -> Void
        init(release: @escaping () -> Void) { self.release = release }
        func finish(_ bit: Int) {
            lock.lock()
            state |= bit
            let done = state == 3
            if done { state = 7 }
            lock.unlock()
            if done { release() }
        }
    }

    init() {
        super.init(frame: .zero, device: MetalWaveformEngine.shared.device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = false
        presentsWithTransaction = true
        #if os(macOS)
        wantsLayer = true
        layer?.isOpaque = false
        #else
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        #endif
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.isOpaque = false
            metalLayer.maximumDrawableCount = 3
        }
        delegate = self
        engine.whenReady { [weak self] in self?.renderLatest() }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    #if os(macOS)
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { renderLatest() }
    }
    override func layout() { super.layout(); renderLatest() }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        pending = latestFrame
        renderLatest()
    }
    #else
    override func layoutSubviews() { super.layoutSubviews(); renderLatest() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        pending = latestFrame
        renderLatest()
    }
    #endif

    func submit(_ frame: MetalWaveformFrame, allowCoalescing: Bool) {
        // Playback meters and unrelated controls can invalidate their SwiftUI
        // ancestors. Identical source/transforms must not cause another GPU pass.
        if let latestFrame, latestFrame.hasSameContent(as: frame) { return }
        latestFrame = frame
        drawableRetryUsed = false
        requiresImmediateSubmission = !allowCoalescing
        if requiresImmediateSubmission {
            // Do not hold every drawable in main-queue presentation callbacks
            // while a non-affine edit synchronously requests another one.
            // Those superseded textures may finish on the GPU and return to
            // the pool without waiting for this same main-thread call to end.
            for presentation in scheduledPresentations.values { presentation.lease.finish(2) }
            scheduledPresentations.removeAll(keepingCapacity: true)
        }
        if pending != nil { coalescedFrameCount &+= 1 }
        pending = frame
        renderLatest()
    }

    private func renderLatest() {
        guard !rendering, window != nil, bounds.width > 0, bounds.height > 0,
              (requiresImmediateSubmission || flights.hasCapacity), let frame = pending, engine.isReady else { return }
        // MTKView acquires its drawable before invoking draw(in:). Resizing in
        // that delegate mixes the new viewport/scissor with the old texture and
        // can erase most of a waveform when a prepared viewport shrinks.
        let pixels = drawablePixels(for: frame, density: backingDensity)
        if drawableSize != pixels {
            rendering = true
            drawableSize = pixels
            rendering = false
        }
        // Encode on demand. Scheduled presentation is asynchronous for affine
        // zoom/pan; the container reprojects its currently displayed texture.
        draw()
    }

    private var backingDensity: CGFloat {
        #if os(macOS)
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        #else
        window?.screen.scale ?? UIScreen.main.scale
        #endif
    }
    private func drawablePixels(for frame: MetalWaveformFrame, density: CGFloat) -> CGSize {
        CGSize(width: max(1, ceil(frame.size.width * density)), height: max(1, ceil(frame.size.height * density)))
    }
    private func retryDrawableOnce() {
        // A system-initiated MTK draw can bypass renderLatest. Preserve the
        // current presentation and retry after that draw releases its drawable.
        // A hidden/unavailable layer must never create a main-queue retry loop.
        guard !drawableRetryUsed else { return }
        drawableRetryUsed = true
        DispatchQueue.main.async { [weak self] in self?.renderLatest() }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard !rendering, let frame = pending,
              frame.size.width > 0, frame.size.height > 0,
              let queue = engine.commandQueue, engine.isReady, flights.begin(ignoringLimit: requiresImmediateSubmission) else { return }
        var committed = false
        rendering = true
        defer {
            rendering = false
            if !committed { flights.end() }
        }
        let density = backingDensity
        let pixels = drawablePixels(for: frame, density: density)
        if drawableSize != pixels { drawableSize = pixels }
        guard let drawable = currentDrawable else { retryDrawableOnce(); return }
        guard drawable.texture.width == Int(pixels.width), drawable.texture.height == Int(pixels.height) else {
            retryDrawableOnce()
            return
        }
        guard let command = queue.makeCommandBuffer() else { return }
        let begin = CACurrentMediaTime()
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clearColor
        guard engine.encode(frame, pass: pass, command: command, density: Float(density), retaining: &visibleBuffers) else { return }
        lastEncodeMilliseconds = (CACurrentMediaTime() - begin) * 1000
        pending = nil
        drawableRetryUsed = false
        submittedFrameCount &+= 1
        command.label = "Timeline waveform viewport"
        let sequence = submittedFrameCount
        let synchronous = requiresImmediateSubmission
        let lease = FrameLease { [weak self, flights] in
            flights.end()
            DispatchQueue.main.async { self?.renderLatest() }
        }
        command.addCompletedHandler { _ in lease.finish(1) }
        let scheduled = CACurrentMediaTime()
        if !synchronous {
            scheduledPresentations[sequence] = ScheduledPresentation(frame: frame, drawable: drawable,
                lease: lease, requestedAt: scheduled)
            command.addScheduledHandler { [weak self] _ in
                DispatchQueue.main.async {
                    defer { lease.finish(2) }
                    guard let self, let presentation = self.scheduledPresentations.removeValue(forKey: sequence) else { return }
                    self.lastScheduleMilliseconds = (CACurrentMediaTime() - presentation.requestedAt) * 1000
                    self.present(presentation.frame, drawable: presentation.drawable, sequence: sequence)
                }
            }
        }
        committed = true
        command.commit()
        if synchronous {
            // A non-affine edit changes individual row/item geometry and cannot
            // use a global texture transform. Keep that edit and its drawable
            // atomic; ordinary zoom/pan never waits here.
            command.waitUntilScheduled()
            lastScheduleMilliseconds = (CACurrentMediaTime() - scheduled) * 1000
            present(frame, drawable: drawable, sequence: sequence)
            lease.finish(2)
        }
    }

    private func present(_ frame: MetalWaveformFrame, drawable: CAMetalDrawable, sequence: UInt64) {
        guard sequence > lastPresentedSequence else { return }
        lastPresentedSequence = sequence
        CATransaction.begin(); CATransaction.setDisableActions(true)
        didPresent?(frame)
        drawable.present()
        CATransaction.commit()

    }
}

/// Device/pipeline and immutable source buffers are shared across all timeline
/// instances. Source upload is once per block/channel, never per zoom frame.
final class MetalWaveformEngine {
    static let shared = MetalWaveformEngine(device: MTLCreateSystemDefaultDevice())
    let device: MTLDevice?
    let commandQueue: MTLCommandQueue?
    private let preparationLock = NSLock()
    private var pipeline: MTLRenderPipelineState?
    private var readyHandlers: [() -> Void] = []
    private let buffers = NSCache<NSString, SourceBuffer>()
    private let allocateSourceBuffer: (UnsafeRawPointer, Int) -> MTLBuffer?
    private(set) var uploadedBufferCount: UInt64 = 0
    private(set) var lastEncodedSegmentCount = 0
    private(set) var lastEncodedStrokeCount = 0
    private(set) var preparationError: String?

    final class SourceBuffer: NSObject {
        let buffer: MTLBuffer
        let pointCount: Int
        init(buffer: MTLBuffer, pointCount: Int) { self.buffer = buffer; self.pointCount = pointCount }
    }

    var isReady: Bool {
        preparationLock.lock(); defer { preparationLock.unlock() }
        return pipeline != nil
    }

    /// Synchronous preparation is exclusively for offscreen GPU validation.
    /// Application startup compiles shaders away from the main thread.
    init(device: MTLDevice?, synchronousPreparation: Bool = false,
         allocateSourceBuffer: ((UnsafeRawPointer, Int) -> MTLBuffer?)? = nil) {
        self.device = device
        commandQueue = device?.makeCommandQueue()
        self.allocateSourceBuffer = allocateSourceBuffer ?? { bytes, size in
            device?.makeBuffer(bytes: bytes, length: size, options: .storageModeShared)
        }
        buffers.totalCostLimit = 64 * 1024 * 1024
        guard device != nil else { return }
        if synchronousPreparation { prepare() }
        else { DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.prepare() } }
    }

    func whenReady(_ handler: @escaping () -> Void) {
        preparationLock.lock()
        if pipeline != nil {
            preparationLock.unlock()
            handler()
        } else {
            readyHandlers.append(handler)
            preparationLock.unlock()
        }
    }

    private func prepare() {
        guard let device else { return }
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Waveform sample capsules and peak intervals"
            descriptor.vertexFunction = library.makeFunction(name: "waveformVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "waveformFragment")
            let colour = descriptor.colorAttachments[0]!
            colour.pixelFormat = .bgra8Unorm
            // Adjacent capsules overlap at their round joins. Maximum coverage
            // prevents dark knots/opacity accumulation in dense waveform areas.
            colour.isBlendingEnabled = true
            colour.rgbBlendOperation = .max
            colour.alphaBlendOperation = .max
            colour.sourceRGBBlendFactor = .one
            colour.destinationRGBBlendFactor = .one
            colour.sourceAlphaBlendFactor = .one
            colour.destinationAlphaBlendFactor = .one
            let compiled = try device.makeRenderPipelineState(descriptor: descriptor)
            preparationLock.lock()
            pipeline = compiled
            let handlers = readyHandlers
            readyHandlers.removeAll()
            preparationLock.unlock()
            DispatchQueue.main.async { handlers.forEach { $0() } }
        } catch {
            preparationLock.lock()
            preparationError = String(describing: error)
            readyHandlers.removeAll()
            preparationLock.unlock()
        }
    }

    private func sourceBuffer(_ block: TimelineAudioWaveform.VertexBlock, channel: Int,
                              retaining old: [String: SourceBuffer], next: inout [String: SourceBuffer]) -> SourceBuffer? {
        guard block.channels.indices.contains(channel), block.channels[channel].count > 1 else { return nil }
        let key = "\(block.key):channel:\(channel)"
        if let cached = old[key] ?? buffers.object(forKey: key as NSString) {
            next[key] = cached
            return cached
        }
        let points = block.channels[channel]
        let size = points.count * MemoryLayout<SIMD2<Float>>.stride
        guard let buffer = points.withUnsafeBufferPointer({ ptr in
            allocateSourceBuffer(ptr.baseAddress!, size)
        }) else { return nil }
        buffer.label = "Waveform \(block.key) ch \(channel)"
        let result = SourceBuffer(buffer: buffer, pointCount: points.count)
        buffers.setObject(result, forKey: key as NSString, cost: size)
        next[key] = result
        uploadedBufferCount &+= 1
        return result
    }

    private struct Uniforms {
        var transform: SIMD4<Float>
        var viewportAndWidth: SIMD4<Float>
        var clip: SIMD4<Float>
        var item: SIMD4<Float>
        var notch: SIMD4<Float>
        var colour: SIMD4<Float>
        var corner: SIMD4<Float>
    }

    @discardableResult
    func encode(_ frame: MetalWaveformFrame, pass: MTLRenderPassDescriptor,
                command: MTLCommandBuffer, density: Float,
                retaining visibleBuffers: inout [String: SourceBuffer]) -> Bool {
        preparationLock.lock()
        let prepared = pipeline
        preparationLock.unlock()
        guard let prepared, frame.size.width > 0, frame.size.height > 0,
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.label = "Batched visible waveform segments"
        encoder.setRenderPipelineState(prepared)
        var retained: [String: SourceBuffer] = [:]
        retained.reserveCapacity(visibleBuffers.count)
        lastEncodedSegmentCount = 0
        lastEncodedStrokeCount = 0
        let viewport = CGRect(origin: .zero, size: frame.size)
        for stroke in frame.strokes {
            let clip = stroke.clip.intersection(stroke.itemRect).intersection(viewport)
            guard !clip.isNull, clip.width > 0, clip.height > 0,
                  stroke.scale.x.isFinite, stroke.scale.y.isFinite,
                  stroke.translation.x.isFinite, stroke.translation.y.isFinite,
                  stroke.lineWidth.isFinite, stroke.lineWidth > 0,
                  stroke.block.channels.indices.contains(stroke.channel),
                  stroke.block.channels[stroke.channel].count > 1 else { continue }
            let range = Self.visibleSegments(stroke, clip: clip)
            guard !range.isEmpty else { continue }
            let pixelMinX = max(0, Int(floor(clip.minX * CGFloat(density))))
            let pixelMinY = max(0, Int(floor(clip.minY * CGFloat(density))))
            let pixelMaxX = min(pass.colorAttachments[0].texture!.width, Int(ceil(clip.maxX * CGFloat(density))))
            let pixelMaxY = min(pass.colorAttachments[0].texture!.height, Int(ceil(clip.maxY * CGFloat(density))))
            guard pixelMaxX > pixelMinX, pixelMaxY > pixelMinY else { continue }
            // Cull before upload. A memory-pressure allocation failure must
            // keep the complete previous drawable, rather than present this
            // pass's clear colour with missing waveform strokes.
            guard let source = sourceBuffer(stroke.block, channel: stroke.channel, retaining: visibleBuffers, next: &retained) else {
                encoder.endEncoding()
                return false
            }
            encoder.setScissorRect(MTLScissorRect(x: pixelMinX, y: pixelMinY, width: pixelMaxX - pixelMinX, height: pixelMaxY - pixelMinY))
            let seam = Float(stroke.firstSeamX ?? 0)
            let spacing = Float(stroke.repeatSpacing ?? 0)
            var uniforms = Uniforms(
                transform: SIMD4(stroke.scale.x, stroke.scale.y, stroke.translation.x, stroke.translation.y),
                viewportAndWidth: SIMD4(Float(frame.size.width), Float(frame.size.height), stroke.lineWidth * 0.5, max(1, density)),
                clip: SIMD4(Float(clip.minX), Float(clip.minY), Float(clip.maxX), Float(clip.maxY)),
                item: SIMD4(Float(stroke.itemRect.minX), Float(stroke.itemRect.minY), Float(stroke.itemRect.maxX), Float(stroke.itemRect.maxY)),
                notch: SIMD4(seam, spacing.isFinite && spacing > 0 ? spacing : 0, 4, 5),
                colour: stroke.color,
                corner: SIMD4(stroke.itemRect.width < 20 ? 0 : max(0, stroke.itemCornerRadius), stroke.block.isPeakEnvelope ? 1 : 0, 0, 0))
            let pointsPerInstance = stroke.block.isPeakEnvelope ? 2 : 1
            encoder.setVertexBuffer(source.buffer, offset: range.lowerBound * pointsPerInstance * MemoryLayout<SIMD2<Float>>.stride, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            // One quad per sample segment or min/max interval. Envelopes cover
            // the entire source interval, including a trim inside one bucket.
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: range.count)
            lastEncodedSegmentCount += range.count
            lastEncodedStrokeCount += 1
        }
        encoder.endEncoding()
        // Pin exactly the visible buffers, independently of NSCache pressure.
        visibleBuffers = retained
        return true
    }

    /// Whole clips are culled by the caller; partially visible source blocks are
    /// culled here by binary search, without walking or tessellating their samples.
    static func visibleSegments(_ stroke: MetalWaveformStroke, clip: CGRect) -> Range<Int> {
        guard stroke.block.channels.indices.contains(stroke.channel) else { return 0..<0 }
        let points = stroke.block.channels[stroke.channel]
        guard points.count > 1 else { return 0..<0 }
        let elementCount = stroke.block.isPeakEnvelope ? points.count / 2 : points.count - 1
        guard abs(stroke.scale.x) > .leastNormalMagnitude else { return 0..<elementCount }
        let padding = stroke.lineWidth * 0.5 + 1
        let first = (Float(clip.minX) - padding - stroke.translation.x) / stroke.scale.x
        let last = (Float(clip.maxX) + padding - stroke.translation.x) / stroke.scale.x
        let minimum = min(first, last), maximum = max(first, last)
        if stroke.block.isPeakEnvelope {
            var left = 0, right = elementCount
            while left < right {
                let middle = (left + right) / 2
                if points[middle * 2 + 1].x < minimum { left = middle + 1 } else { right = middle }
            }
            let start = left
            right = elementCount
            while left < right {
                let middle = (left + right) / 2
                if points[middle * 2].x <= maximum { left = middle + 1 } else { right = middle }
            }
            return start..<left
        }
        func lowerBound(_ value: Float) -> Int {
            var left = 0, right = points.count
            while left < right {
                let middle = (left + right) / 2
                if points[middle].x < value { left = middle + 1 } else { right = middle }
            }
            return left
        }
        let start = max(0, lowerBound(minimum) - 1)
        let end = min(points.count - 1, lowerBound(maximum))
        return start..<max(start, end)
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct WaveformUniforms {
        float4 transform;
        float4 viewportAndWidth;
        float4 clip;
        float4 item;
        float4 notch;
        float4 colour;
        float4 corner;
    };
    struct WaveformRaster {
        float4 position [[position]];
        float2 local;
        float2 screen;
        float length [[flat]];
        float peakHalfHeight [[flat]];
    };
    vertex WaveformRaster waveformVertex(uint vertexID [[vertex_id]], uint segment [[instance_id]],
                                         const device float2 *points [[buffer(0)]],
                                         constant WaveformUniforms &u [[buffer(1)]]) {
        const float2 corners[6] = {float2(0,-1),float2(1,-1),float2(0,1),
                                    float2(0,1),float2(1,-1),float2(1,1)};
        WaveformRaster out;
        float2 corner = corners[vertexID];
        if (u.corner.y > 0) {
            float2 a = points[segment * 2] * u.transform.xy + u.transform.zw;
            float2 b = points[segment * 2 + 1] * u.transform.xy + u.transform.zw;
            float2 center = (a + b) * 0.5;
            float2 halfSize = max(abs(b - a) * 0.5, float2(0.5 / u.viewportAndWidth.w));
            float2 local = float2(mix(-halfSize.x, halfSize.x, corner.x),
                                  corner.y * (halfSize.y + 1.0 / u.viewportAndWidth.w));
            float2 screen = center + local;
            out.position = float4(screen.x / u.viewportAndWidth.x * 2.0 - 1.0,
                                  1.0 - screen.y / u.viewportAndWidth.y * 2.0, 0, 1);
            out.local = local;
            out.screen = screen;
            out.length = 0;
            out.peakHalfHeight = halfSize.y;
            return out;
        }
        float2 a = points[segment] * u.transform.xy + u.transform.zw;
        float2 b = points[segment + 1] * u.transform.xy + u.transform.zw;
        float2 delta = b - a;
        float length = metal::length(delta);
        float2 tangent = length > 0.000001 ? delta / length : float2(1, 0);
        float2 normal = float2(-tangent.y, tangent.x);
        float expansion = u.viewportAndWidth.z + 1.0 / u.viewportAndWidth.w;
        float2 local = float2(mix(-expansion, length + expansion, corner.x), corner.y * expansion);
        float2 screen = a + tangent * local.x + normal * local.y;
        out.position = float4(screen.x / u.viewportAndWidth.x * 2.0 - 1.0,
                              1.0 - screen.y / u.viewportAndWidth.y * 2.0, 0, 1);
        out.local = local;
        out.screen = screen;
        out.length = length;
        out.peakHalfHeight = 0;
        return out;
    }
    fragment float4 waveformFragment(WaveformRaster in [[stage_in]],
                                      constant WaveformUniforms &u [[buffer(1)]]) {
        if (in.screen.x < u.clip.x || in.screen.y < u.clip.y ||
            in.screen.x > u.clip.z || in.screen.y > u.clip.w) discard_fragment();
        float coverage;
        if (u.corner.y > 0) {
            // Adjacent bins meet with full coverage: antialias their upper and
            // lower envelope edges without transparent vertical seams.
            coverage = saturate((in.peakHalfHeight - abs(in.local.y)) * u.viewportAndWidth.w + 0.5);
        } else {
            float2 distanceVector = float2(in.local.x - clamp(in.local.x, 0.0, in.length), in.local.y);
            float distance = length(distanceVector);
            coverage = saturate((u.viewportAndWidth.z - distance) * u.viewportAndWidth.w + 0.5);
        }
        float2 itemCenter = (u.item.xy + u.item.zw) * 0.5;
        float2 itemHalf = (u.item.zw - u.item.xy) * 0.5;
        float radius = min(u.corner.x, min(itemHalf.x, itemHalf.y));
        float2 q = abs(in.screen - itemCenter) - itemHalf + radius;
        float itemDistance = length(max(q, float2(0))) + min(max(q.x, q.y), 0.0) - radius;
        coverage *= saturate(0.5 - itemDistance * u.viewportAndWidth.w);
        if (u.notch.y > 0) {
            float seam = u.notch.x + round((in.screen.x - u.notch.x) / u.notch.y) * u.notch.y;
            if (seam > u.item.x + 0.01 && seam < u.item.z - 0.01) {
                float dx = abs(in.screen.x - seam);
                float notchTop = u.item.w - u.notch.w + dx * (u.notch.w / u.notch.z);
                // Fixed-size triangular cut-out on the bottom border only.
                if (dx < u.notch.z) coverage *= saturate((notchTop - in.screen.y) * u.viewportAndWidth.w + 0.5);
            }
        }
        float alpha = coverage * u.colour.a;
        return float4(u.colour.rgb * alpha, alpha);
    }
    """
}
