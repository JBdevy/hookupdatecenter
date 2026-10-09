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

/// Item decoration stays independent of waveform readiness. Viewport-local
/// rectangles keep GPU arithmetic precise even very far along the timeline.
struct MetalTimelineItem: Equatable {
    let rect: CGRect
    let topColor: SIMD4<Float>
    let bottomColor: SIMD4<Float>
    let borderColor: SIMD4<Float>
    var cornerRadius: Float = 3
    var borderWidth: Float = 0.6
    var headerHeight: Float = 0
    var firstSeamX: CGFloat? = nil
    var repeatSpacing: CGFloat? = nil
}

struct MetalWaveformFrame {
    let size: CGSize
    let strokes: [MetalWaveformStroke]
    var coordinateSpace: MetalWaveformCoordinateSpace? = nil
    var items: [MetalTimelineItem] = []
    var isEmpty: Bool { strokes.isEmpty && items.isEmpty }

    func hasSameContent(as other: MetalWaveformFrame) -> Bool {
        coordinateSpace == other.coordinateSpace && size == other.size && items == other.items && strokes.count == other.strokes.count && zip(strokes, other.strokes).allSatisfy { a, b in
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

/// Each zoom frame draws source peak vertices at the current scale. The child
/// always uses the viewport's native pixel size; a previous bitmap is never
/// enlarged or translated to impersonate a waveform at another scale.
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
        // Only source-detail replacements with identical geometry may wait for
        // a free slot. Zoom, pan and edits present their new vertices in the
        // same transaction as the items and ruler, without bitmap reprojection.
        let sameGeometry = presented.map {
            $0.coordinateSpace != nil && $0.coordinateSpace == frame.coordinateSpace && $0.size == frame.size
        } ?? false
        renderer.submit(frame, allowCoalescing: sameGeometry)
    }
    private func applyPresentationGeometry() {
        guard let latest, !latest.isEmpty else { return }
        let rect = CGRect(origin: .zero, size: latest.size)
        let disabled = CATransaction.disableActions()
        CATransaction.setDisableActions(true)
        defer { CATransaction.setDisableActions(disabled) }
        if renderer.frame != rect { renderer.frame = rect }
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
        let frameRequestedAt: Double
    }
    private var scheduledPresentations: [UInt64: ScheduledPresentation] = [:]
    private var requiresImmediateSubmission = false
    private let engine = MetalWaveformEngine.shared
    private var latestFrame: MetalWaveformFrame?
    private var pending: MetalWaveformFrame?
    private var pendingRequestedAt: Double = 0
    private var visibleBuffers: MetalWaveformEngine.SourceBuffers = [:]
    private let flights = FrameGate()
    private var rendering = false
    private var drawableRetryUsed = false
    #if os(macOS)
    private var windowVisibility: NSKeyValueObservation?
    private var windowOcclusion: NSObjectProtocol?
    #endif
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
        windowVisibility = nil
        if let windowOcclusion { NotificationCenter.default.removeObserver(windowOcclusion) }
        windowOcclusion = nil
        if let window {
            windowVisibility = window.observe(\.isVisible, options: [.new]) { [weak self] window, _ in
                guard window.isVisible else { return }
                MainActor.assumeIsolated { self?.retryPendingContent() }
            }
            windowOcclusion = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard self?.window?.occlusionState.contains(.visible) == true else { return }
                        self?.retryPendingContent()
                    }
                }
        }
        if window != nil { renderLatest() }
    }
    override func viewDidUnhide() { super.viewDidUnhide(); retryPendingContent() }
    override func layout() { super.layout(); renderLatest() }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        pending = latestFrame
        pendingRequestedAt = TimelineRenderDiagnostics.enabled ? CACurrentMediaTime() : 0
        renderLatest()
    }
    #else
    override func layoutSubviews() { super.layoutSubviews(); renderLatest() }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        pending = latestFrame
        pendingRequestedAt = TimelineRenderDiagnostics.enabled ? CACurrentMediaTime() : 0
        renderLatest()
    }
    #endif

    func submit(_ frame: MetalWaveformFrame, allowCoalescing: Bool) {
        // Playback meters and unrelated controls can invalidate their SwiftUI
        // ancestors. Identical source/transforms must not cause another GPU pass.
        if let latestFrame, latestFrame.hasSameContent(as: frame) {
            // A startup drawable can be unavailable through the bounded retry.
            // Identical pending content still needs presentation; content that
            // already submitted remains idle. A later submit can retry it.
            retryPendingContent()
            return
        }
        latestFrame = frame
        // An empty viewport has no GPU work. Hide any old drawable immediately
        // and invalidate delayed presentations instead of allocating, clearing
        // and scheduling a transparent Retina texture on every zoom frame.
        if frame.isEmpty {
            pending = nil
            visibleBuffers.removeAll(keepingCapacity: false)
            for presentation in scheduledPresentations.values { presentation.lease.finish(2) }
            scheduledPresentations.removeAll(keepingCapacity: true)
            lastPresentedSequence = submittedFrameCount
            setContentVisible(false)
            didPresent?(frame)
            return
        }
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
        pendingRequestedAt = TimelineRenderDiagnostics.enabled ? CACurrentMediaTime() : 0
        renderLatest()
    }

    private func renderLatest() {
        guard !rendering, window != nil, bounds.width > 0, bounds.height > 0,
              (requiresImmediateSubmission || flights.hasCapacity), let frame = pending, !frame.isEmpty, engine.isReady else { return }
        // MTKView acquires its drawable before invoking draw(in:). Resizing in
        // that delegate mixes the new viewport/scissor with the old texture and
        // can erase most of a waveform when a prepared viewport shrinks.
        let pixels = drawablePixels(for: frame, density: backingDensity)
        if drawableSize != pixels {
            rendering = true
            drawableSize = pixels
            rendering = false
        }
        // Encode peak vertices at this frame's scale. Geometry changes submit
        // within the current layout transaction; no old texture is scaled.
        draw()
    }

    /// Projection caches may not submit again when a hidden window becomes
    /// drawable. Recover only unfinished content; ready surfaces stay idle.
    private func retryPendingContent() {
        guard pending != nil else { return }
        drawableRetryUsed = false
        renderLatest()
    }

    deinit {
        #if os(macOS)
        if let windowOcclusion { NotificationCenter.default.removeObserver(windowOcclusion) }
        #endif
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
        guard !rendering else { return }
        // AppKit can invalidate the drawable while the timeline projection is
        // unchanged (backing updates, unhide, resizing another panel). A draw
        // notification is a request to restore pixels, not a new model submit.
        // Keep the retained scene available even after pending was consumed.
        if pending == nil, let latestFrame, !latestFrame.isEmpty {
            pending = latestFrame
            pendingRequestedAt = TimelineRenderDiagnostics.enabled ? CACurrentMediaTime() : 0
            requiresImmediateSubmission = true
            drawableRetryUsed = false
        }
        guard let frame = pending, !frame.isEmpty,
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
        let frameRequestedAt = pendingRequestedAt
        let pixelWidth = Double(drawable.texture.width), pixelHeight = Double(drawable.texture.height)
        if TimelineRenderDiagnostics.enabled {
            TimelineRenderDiagnostics.record("metal.encode", width: pixelWidth, height: pixelHeight,
                milliseconds: lastEncodeMilliseconds)
        }
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
        command.addCompletedHandler { completed in
            lease.finish(1)
            if TimelineRenderDiagnostics.enabled, completed.gpuStartTime > 0,
               completed.gpuEndTime >= completed.gpuStartTime {
                TimelineRenderDiagnostics.record("metal.gpu", width: pixelWidth, height: pixelHeight,
                    milliseconds: (completed.gpuEndTime - completed.gpuStartTime) * 1000)
            }
        }
        let scheduled = CACurrentMediaTime()
        if !synchronous {
            scheduledPresentations[sequence] = ScheduledPresentation(frame: frame, drawable: drawable,
                lease: lease, requestedAt: scheduled, frameRequestedAt: frameRequestedAt)
            command.addScheduledHandler { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, let presentation = self.scheduledPresentations.removeValue(forKey: sequence) else {
                        lease.finish(2); return
                    }
                    self.lastScheduleMilliseconds = (CACurrentMediaTime() - presentation.requestedAt) * 1000
                    if TimelineRenderDiagnostics.enabled {
                        TimelineRenderDiagnostics.record("metal.schedule", width: pixelWidth, height: pixelHeight,
                            milliseconds: self.lastScheduleMilliseconds)
                    }
                    self.present(presentation.frame, drawable: presentation.drawable, sequence: sequence, lease: lease,
                        requestedAt: presentation.frameRequestedAt)
                }
            }
        }
        committed = true
        command.commit()
        if synchronous {
            // Coordinate changes and their drawable must commit atomically.
            // Wait for command scheduling, not GPU completion or audio decoding.
            command.waitUntilScheduled()
            lastScheduleMilliseconds = (CACurrentMediaTime() - scheduled) * 1000
            if TimelineRenderDiagnostics.enabled {
                TimelineRenderDiagnostics.record("metal.schedule", width: pixelWidth, height: pixelHeight,
                    milliseconds: lastScheduleMilliseconds)
            }
            present(frame, drawable: drawable, sequence: sequence, lease: lease, requestedAt: frameRequestedAt)
        }
    }

    private func present(_ frame: MetalWaveformFrame, drawable: CAMetalDrawable, sequence: UInt64,
                         lease: FrameLease, requestedAt: Double) {
        guard sequence > lastPresentedSequence, latestFrame?.isEmpty == false else { lease.finish(2); return }
        // Calling present only queues the drawable. Releasing the slot there
        // can exhaust the triple buffer before Core Animation displays it and
        // make nextDrawable block the UI thread for an entire timeout.
        let pixelWidth = Double(drawable.texture.width), pixelHeight = Double(drawable.texture.height)
        drawable.addPresentedHandler { presented in
            let timestamp = TimelineRenderDiagnostics.enabled ? presented.presentedTime : 0
            lease.finish(2)
            if TimelineRenderDiagnostics.enabled, timestamp > 0, requestedAt > 0 {
                // Read the display timestamp in this callback. Dispatching to
                // the main queue would measure busy-run-loop delay instead.
                TimelineRenderDiagnostics.record("metal.present", width: pixelWidth, height: pixelHeight,
                    milliseconds: max(0, timestamp - requestedAt) * 1000, eventTime: timestamp)
            }
        }
        lastPresentedSequence = sequence
        // Join the run loop's implicit transaction. Starting and committing a
        // root explicit transaction from each GPU callback forces AppKit to
        // flush layout and cursor hit testing again between display frames.
        // Geometry and drawable still commit together at the display boundary.
        let disabled = CATransaction.disableActions()
        CATransaction.setDisableActions(true)
        defer { CATransaction.setDisableActions(disabled) }
        didPresent?(frame)
        setContentVisible(true)
        drawable.present()
    }
    private func setContentVisible(_ visible: Bool) {
        let opacity: CGFloat = visible ? 1 : 0
        // Even an identical AppKit alpha setter invalidates view compositing
        // and vibrancy through the hierarchy. A presented frame is normally
        // already visible, so only visibility transitions touch that property.
        #if os(macOS)
        guard alphaValue != opacity else { return }
        #else
        guard alpha != opacity else { return }
        #endif
        let disabled = CATransaction.disableActions()
        CATransaction.setDisableActions(true)
        defer { CATransaction.setDisableActions(disabled) }
        #if os(macOS)
        alphaValue = opacity
        #else
        alpha = opacity
        #endif
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
    private var itemPipeline: MTLRenderPipelineState?
    private var readyHandlers: [() -> Void] = []
    private let buffers = NSCache<BufferCacheKey, SourceBuffer>()
    private let allocateSourceBuffer: (UnsafeRawPointer, Int) -> MTLBuffer?
    private(set) var uploadedBufferCount: UInt64 = 0
    private(set) var lastEncodedSegmentCount = 0
    private(set) var lastEncodedStrokeCount = 0
    private(set) var lastEncodedItemCount = 0
    private(set) var preparationError: String?

    final class SourceBuffer: NSObject {
        let buffer: MTLBuffer
        let pointCount: Int
        init(buffer: MTLBuffer, pointCount: Int) { self.buffer = buffer; self.pointCount = pointCount }
    }

    /// Reuse the source key's worker-computed hash. Keep semantic equality so
    /// evicted/recreated CPU blocks can still reuse an existing GPU buffer.
    private final class BufferCacheKey: NSObject {
        let source: String
        let channel: Int
        private let cachedHash: Int
        init(block: TimelineAudioWaveform.VertexBlock, channel: Int) {
            source = block.key; self.channel = channel
            var hasher = Hasher()
            hasher.combine(block.keyHash); hasher.combine(channel)
            cachedHash = hasher.finalize()
        }
        override var hash: Int { cachedHash }
        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? BufferCacheKey else { return false }
            return channel == other.channel && source == other.source
        }
    }

    /// Visible strokes reuse the same immutable block objects. Hash their
    /// identity instead of normalizing a full Unicode media path every frame.
    /// Retaining the block in the key prevents its address from being reused
    /// while an earlier GPU buffer is still visible.
    struct SourceBufferKey: Hashable {
        let block: TimelineAudioWaveform.VertexBlock
        let channel: Int
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.block === rhs.block && lhs.channel == rhs.channel }
        func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(block))
            hasher.combine(channel)
        }
    }
    typealias SourceBuffers = [SourceBufferKey: SourceBuffer]

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
            let itemDescriptor = MTLRenderPipelineDescriptor()
            itemDescriptor.label = "Timeline item gradients, headers and loop notches"
            itemDescriptor.vertexFunction = library.makeFunction(name: "timelineItemVertex")
            itemDescriptor.fragmentFunction = library.makeFunction(name: "timelineItemFragment")
            let itemColor = itemDescriptor.colorAttachments[0]!
            itemColor.pixelFormat = .bgra8Unorm
            itemColor.isBlendingEnabled = true
            itemColor.sourceRGBBlendFactor = .one
            itemColor.sourceAlphaBlendFactor = .one
            itemColor.destinationRGBBlendFactor = .oneMinusSourceAlpha
            itemColor.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            let compiledItems = try device.makeRenderPipelineState(descriptor: itemDescriptor)
            preparationLock.lock()
            pipeline = compiled
            itemPipeline = compiledItems
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
                              retaining old: SourceBuffers, next: inout SourceBuffers) -> SourceBuffer? {
        guard block.channels.indices.contains(channel), block.channels[channel].count > 1 else { return nil }
        let identity = SourceBufferKey(block: block, channel: channel)
        if let cached = next[identity] { return cached }
        if let cached = old[identity] {
            next[identity] = cached
            return cached
        }
        // A newly reconstructed block can still share an already uploaded
        // source buffer. Only this cold identity path needs the semantic key.
        let key = BufferCacheKey(block: block, channel: channel)
        if let cached = buffers.object(forKey: key) {
            next[identity] = cached
            return cached
        }
        let points = block.channels[channel]
        let size = points.count * MemoryLayout<SIMD2<Float>>.stride
        guard let buffer = points.withUnsafeBufferPointer({ ptr in
            allocateSourceBuffer(ptr.baseAddress!, size)
        }) else { return nil }
        buffer.label = "Waveform \(block.key) ch \(channel)"
        let result = SourceBuffer(buffer: buffer, pointCount: points.count)
        buffers.setObject(result, forKey: key, cost: size)
        next[identity] = result
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

    private struct ItemUniforms {
        var rect: SIMD4<Float>
        var top: SIMD4<Float>
        var bottom: SIMD4<Float>
        var border: SIMD4<Float>
        var style: SIMD4<Float>
        var notch: SIMD4<Float>
    }

    @discardableResult
    func encode(_ frame: MetalWaveformFrame, pass: MTLRenderPassDescriptor,
                command: MTLCommandBuffer, density: Float,
                retaining visibleBuffers: inout SourceBuffers) -> Bool {
        preparationLock.lock()
        let prepared = pipeline
        let preparedItems = itemPipeline
        preparationLock.unlock()
        guard let prepared, frame.size.width > 0, frame.size.height > 0,
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.label = "Batched visible waveform segments"
        encoder.setRenderPipelineState(prepared)
        var retained: SourceBuffers = [:]
        retained.reserveCapacity(visibleBuffers.count)
        lastEncodedSegmentCount = 0
        lastEncodedStrokeCount = 0
        lastEncodedItemCount = 0
        let viewport = CGRect(origin: .zero, size: frame.size)
        // Decorations are submitted on their own surface below waveforms.
        // Waveform maximum-coverage blending must never blend over a fill.
        if !frame.items.isEmpty, let preparedItems {
            encoder.setRenderPipelineState(preparedItems)
            var screen = SIMD4(Float(frame.size.width), Float(frame.size.height), max(1, density), 0)
            encoder.setVertexBytes(&screen, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            encoder.setFragmentBytes(&screen, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            var batch: [ItemUniforms] = []
            batch.reserveCapacity(32)
            func flush() {
                guard !batch.isEmpty else { return }
                batch.withUnsafeBytes { bytes in
                    encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
                    encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
                }
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: batch.count)
                lastEncodedItemCount += batch.count
                batch.removeAll(keepingCapacity: true)
            }
            for item in frame.items {
                let r = item.rect
                guard r.minX.isFinite, r.minY.isFinite, r.width.isFinite, r.height.isFinite,
                    r.width > 0, r.height > 0, r.insetBy(dx: -2, dy: -2).intersects(viewport) else { continue }
                let spacing = Float(item.repeatSpacing ?? 0)
                batch.append(ItemUniforms(rect: SIMD4(Float(r.minX), Float(r.minY), Float(r.maxX), Float(r.maxY)),
                    top: item.topColor, bottom: item.bottomColor, border: item.borderColor,
                    style: SIMD4(max(0, item.cornerRadius), max(0, item.borderWidth), max(0, item.headerHeight), 0),
                    notch: SIMD4(Float(item.firstSeamX ?? 0), spacing.isFinite && spacing > 0 ? spacing : 0, 4, min(5, Float(r.height) / 3))))
                if batch.count == 32 { flush() }
            }
            flush()
            encoder.setRenderPipelineState(prepared)
        }
        // Render-target dimensions are immutable throughout this pass. Avoid
        // crossing the Objective-C attachment/texture accessors per stroke.
        let target = pass.colorAttachments[0].texture
        let targetWidth = target?.width ?? 0, targetHeight = target?.height ?? 0
        var scissor = MTLScissorRect(x: 0, y: 0, width: 0, height: 0)
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
            let pixelMaxX = min(targetWidth, Int(ceil(clip.maxX * CGFloat(density))))
            let pixelMaxY = min(targetHeight, Int(ceil(clip.maxY * CGFloat(density))))
            guard pixelMaxX > pixelMinX, pixelMaxY > pixelMinY else { continue }
            // Cull before upload. A memory-pressure allocation failure must
            // keep the complete previous drawable, rather than present this
            // pass's clear colour with missing waveform strokes.
            guard let source = sourceBuffer(stroke.block, channel: stroke.channel, retaining: visibleBuffers, next: &retained) else {
                encoder.endEncoding()
                return false
            }
            let pixelWidth = pixelMaxX - pixelMinX, pixelHeight = pixelMaxY - pixelMinY
            if scissor.x != pixelMinX || scissor.y != pixelMinY || scissor.width != pixelWidth || scissor.height != pixelHeight {
                scissor = MTLScissorRect(x: pixelMinX, y: pixelMinY, width: pixelWidth, height: pixelHeight)
                encoder.setScissorRect(scissor)
            }
            let seam = Float(stroke.firstSeamX ?? 0)
            let spacing = Float(stroke.repeatSpacing ?? 0)
            var uniforms = Uniforms(
                transform: SIMD4(stroke.scale.x, stroke.scale.y, stroke.translation.x, stroke.translation.y),
                viewportAndWidth: SIMD4(Float(frame.size.width), Float(frame.size.height), stroke.lineWidth * 0.5, max(1, density)),
                clip: SIMD4(Float(clip.minX), Float(clip.minY), Float(clip.maxX), Float(clip.maxY)),
                item: SIMD4(Float(stroke.itemRect.minX), Float(stroke.itemRect.minY), Float(stroke.itemRect.maxX), Float(stroke.itemRect.maxY)),
                notch: SIMD4(seam, spacing.isFinite && spacing > 0 ? spacing : 0, 4, 5),
                colour: stroke.color,
                corner: SIMD4(stroke.itemRect.width < 20 ? 0 : max(0, stroke.itemCornerRadius), stroke.block.isPeakEnvelope ? 1 : 0, Float(stroke.block.channels[stroke.channel].count / 2), Float(range.lowerBound)))
            let pointsPerInstance = stroke.block.isPeakEnvelope ? 2 : 1
            encoder.setVertexBuffer(source.buffer, offset: stroke.block.isPeakEnvelope ? 0 : range.lowerBound * pointsPerInstance * MemoryLayout<SIMD2<Float>>.stride, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            // One quad per sample segment or min/max interval. Envelopes cover
            // the entire source interval, including a trim inside one bucket.
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: stroke.block.isPeakEnvelope ? 12 : 6, instanceCount: range.count)
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
        // Interior blocks are already fully visible. Only viewport-edge
        // blocks need binary searches. Keep the strict upper comparison: a
        // contour can end in repeated x positions, whose exact boundary must
        // still follow lowerBound's existing segment selection.
        let lastPoint = stroke.block.isPeakEnvelope ? elementCount * 2 - 1 : points.count - 1
        if minimum <= points[0].x, maximum > points[lastPoint].x { return 0..<elementCount }
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
    struct TimelineItemUniforms {
        float4 rect, top, bottom, border, style, notch;
    };
    struct TimelineItemOut {
        float4 position [[position]];
        float2 screen;
        uint item [[flat]];
    };
    vertex TimelineItemOut timelineItemVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
        constant TimelineItemUniforms *items [[buffer(0)]], constant float4 &screen [[buffer(1)]]) {
        const float2 corners[] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(0, 1), float2(1, 0), float2(1, 1) };
        TimelineItemUniforms u = items[instanceID];
        float padding = u.style.y * 0.5 + 1.0 / screen.z;
        float2 lower = max(u.rect.xy - padding, float2(0));
        float2 upper = min(u.rect.zw + padding, screen.xy);
        float2 point = mix(lower, upper, corners[vertexID]);
        TimelineItemOut out;
        out.screen = point;
        out.position = float4(point.x / screen.x * 2 - 1, 1 - point.y / screen.y * 2, 0, 1);
        out.item = instanceID;
        return out;
    }
    fragment float4 timelineItemFragment(TimelineItemOut in [[stage_in]],
        constant TimelineItemUniforms *items [[buffer(0)]], constant float4 &screen [[buffer(1)]]) {
        TimelineItemUniforms u = items[in.item];
        float2 extent = u.rect.zw - u.rect.xy;
        float radius = min(u.style.x, min(extent.x, extent.y) * 0.5);
        // Distances from individual edges avoid cancellation at extreme zoom.
        float2 edges = min(in.screen - u.rect.xy, u.rect.zw - in.screen);
        float2 q = radius - edges;
        float distance = length(max(q, float2(0))) + min(max(q.x, q.y), 0.0) - radius;
        if (u.notch.y > 0) {
            float seam = u.notch.x + round((in.screen.x - u.notch.x) / u.notch.y) * u.notch.y;
            if (seam > u.rect.x + radius && seam < u.rect.z - radius) {
                float dx = abs(in.screen.x - seam);
                if (dx < u.notch.z) {
                    float slope = u.notch.w / u.notch.z;
                    float top = u.rect.w - u.notch.w + dx * slope;
                    distance = max(distance, (in.screen.y - top) / sqrt(1 + slope * slope));
                }
            }
        }
        float fillCoverage = saturate(0.5 - distance * screen.z);
        float t = saturate((in.screen.y - u.rect.y) / max(1.0, extent.y));
        float4 fill = mix(u.top, u.bottom, t);
        float alpha = fill.a * fillCoverage;
        float3 rgb = fill.rgb * alpha;
        if (u.style.z > 0 && in.screen.y < u.rect.y + u.style.z) {
            float headerAlpha = 0.16 * fillCoverage;
            rgb *= (1 - headerAlpha);
            alpha = headerAlpha + alpha * (1 - headerAlpha);
        }
        float strokeCoverage = u.style.y > 0 ? saturate(0.5 + (u.style.y * 0.5 - abs(distance)) * screen.z) : 0;
        float strokeAlpha = u.border.a * strokeCoverage;
        return float4(u.border.rgb * strokeAlpha + rgb * (1 - strokeAlpha), strokeAlpha + alpha * (1 - strokeAlpha));
    }

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
        float peakHalfHeight;
    };
    vertex WaveformRaster waveformVertex(uint vertexID [[vertex_id]], uint segment [[instance_id]],
                                         const device float2 *points [[buffer(0)]],
                                         constant WaveformUniforms &u [[buffer(1)]]) {
        const float2 corners[6] = {float2(0,-1),float2(1,-1),float2(0,1),
                                    float2(0,1),float2(1,-1),float2(1,1)};
        WaveformRaster out;
        float2 corner = corners[vertexID % 6];
        if (u.corner.y > 0) {
            uint bucket = segment + uint(u.corner.w);
            float2 a = points[bucket * 2] * u.transform.xy + u.transform.zw;
            float2 b = points[bucket * 2 + 1] * u.transform.xy + u.transform.zw;
            float centerX = (a.x + b.x) * 0.5;
            float halfWidth = max(abs(b.x - a.x) * 0.5, 0.5 / u.viewportAndWidth.w);
            a.x = centerX - halfWidth; b.x = centerX + halfWidth;
            float2 extrema = float2(min(a.y, b.y), max(a.y, b.y));
            float2 leftEdge = extrema, rightEdge = extrema;
            // Two half-bins join neighbouring peak centers. Retain each real
            // min/max at its center rather than flattening it into a rectangle.
            if (bucket > 0 && points[bucket * 2 - 1].x == points[bucket * 2].x) {
                float2 previous = float2(points[bucket * 2 - 2].y, points[bucket * 2 - 1].y) * u.transform.y + u.transform.w;
                leftEdge = (extrema + float2(min(previous.x, previous.y), max(previous.x, previous.y))) * 0.5;
            }
            if (bucket + 1 < uint(u.corner.z) && points[bucket * 2 + 2].x == points[bucket * 2 + 1].x) {
                float2 next = float2(points[bucket * 2 + 2].y, points[bucket * 2 + 3].y) * u.transform.y + u.transform.w;
                rightEdge = (extrema + float2(min(next.x, next.y), max(next.x, next.y))) * 0.5;
            }
            bool second = vertexID >= 6;
            float2 edge = second ? mix(extrema, rightEdge, corner.x) : mix(leftEdge, extrema, corner.x);
            float x = mix(a.x, b.x, (corner.x + (second ? 1.0 : 0.0)) * 0.5);
            float centerY = (edge.x + edge.y) * 0.5;
            float halfHeight = max((edge.y - edge.x) * 0.5, 0.5 / u.viewportAndWidth.w);
            float y = corner.y * (halfHeight + 1.0 / u.viewportAndWidth.w);
            float2 screen = float2(x, centerY + y);
            out.position = float4(screen.x / u.viewportAndWidth.x * 2.0 - 1.0,
                                  1.0 - screen.y / u.viewportAndWidth.y * 2.0, 0, 1);
            out.local = float2(0, y);
            out.screen = screen;
            out.length = 0;
            out.peakHalfHeight = halfHeight;
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
