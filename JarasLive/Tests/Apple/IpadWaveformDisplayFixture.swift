import SwiftUI
import UIKit

@main struct WaveformDisplayFixture: App {
    var body: some Scene { WindowGroup { WaveformDisplayFixtureView() } }
}
@MainActor final class WaveformDisplayResult: ObservableObject {
    static let shared = WaveformDisplayResult()
    @Published var value = "Running"
}
struct WaveformDisplayFixtureView: View {
    @ObservedObject var result = WaveformDisplayResult.shared
    var body: some View {
        VStack {
            Text(result.value).accessibilityIdentifier("waveform-display-result")
            WaveformDisplayDriver().frame(width: 512, height: 128)
        }
    }
}
struct WaveformDisplayDriver: UIViewRepresentable {
    func makeUIView(context: Context) -> WaveformDisplayHost { WaveformDisplayHost() }
    func updateUIView(_ view: WaveformDisplayHost, context: Context) {}
}
final class WaveformDisplayHost: UIView {
    private let surface = MetalWaveformSurface()
    private var started = false
    override init(frame: CGRect) { super.init(frame: frame); addSubview(surface) }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func layoutSubviews() { super.layoutSubviews(); surface.frame = bounds }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !started else { return }
        started = true
        Task { @MainActor in await verify() }
    }
    private func verify() async {
        func fail(_ message: String) { WaveformDisplayResult.shared.value = "FAIL: " + message }
        func wait(_ condition: () -> Bool) async -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return condition()
        }
        guard await wait({ MetalWaveformRenderer.isSupported && self.bounds.width > 0 }) else { fail("Metal unavailable"); return }
        if let error = verifyOverviewPixels() { fail(error); return }
        let block = TimelineAudioWaveform.VertexBlock(channels: [[SIMD2<Float>(0, 0), SIMD2<Float>(1, 1), SIMD2<Float>(2, 0)]],
            start: 0, end: 2, step: 1, rate: 1, key: "ipad-pan-display")
        func frame(_ origin: Double, span: Double = 5.12) -> MetalWaveformFrame {
            let rect = CGRect(origin: .zero, size: self.bounds.size)
            let scale = Float(rect.width / span)
            let item = CGRect(x: CGFloat(2 * scale) - origin, y: 0, width: CGFloat(2 * scale), height: rect.height)
            let stroke = MetalWaveformStroke(block: block, channel: 0, scale: SIMD2(scale, 32),
                translation: SIMD2(Float(item.minX), 60), clip: rect, color: SIMD4(repeating: 1), itemRect: item)
            return MetalWaveformFrame(size: rect.size, strokes: [stroke],
                coordinateSpace: .init(documentOrigin: CGPoint(x: origin, y: 0), pixelsPerSecond: Double(scale), contentRevision: 1))
        }
        surface.submit(frame(0))
        guard await wait({ self.surface.displayedOriginForPanTest == 0 }) else { fail("initial waveform never presented"); return }
        try? await Task.sleep(nanoseconds: 150_000_000)
        let before = surface.submittedFrameCount
        // A rapid pan may deliver several model updates before UIKit commits
        // the item/header layers. None may present its waveform independently.
        for index in 1...120 { surface.submit(frame(Double(index))) }
        guard surface.submittedFrameCount == before else { fail("waveform rendered before UIKit's item display pass"); return }
        guard await wait({ self.surface.displayedOriginForPanTest == 120 }) else { fail("latest pan position never presented"); return }
        let afterPan = surface.submittedFrameCount
        guard afterPan <= before + 2 else { fail("superseded pan positions were queued"); return }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let idle = surface.submittedFrameCount
        for _ in 0..<100 { surface.submit(frame(120)) }
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard surface.submittedFrameCount == idle else { fail("waveform continued rendering after pan stopped"); return }
        // Exercise both zoom limits, including items narrower than one pixel.
        // Each new viewport must reach the compositor without resizing the row
        // or presenting one of the superseded intermediate transforms.
        for span in [86_400.0, 0.25, 86_400.0, 60.0] {
            let beforeZoom = surface.submittedFrameCount
            for index in 1...120 { surface.submit(frame(0, span: span + Double(120 - index))) }
            guard surface.submittedFrameCount == beforeZoom else { fail("zoom rendered outside UIKit display pass"); return }
            let expected = Double(Float(bounds.width / span))
            guard await wait({ self.surface.displayedScaleForZoomTest == expected }) else { fail("zoom limit never presented"); return }
            guard surface.presentedContentFrame == bounds else { fail("zoom changed waveform row bounds"); return }
        }
        WaveformDisplayResult.shared.value = "PASS: stable overview pixels; UIKit pan and zoom synchronized; latest frame only; stable row bounds"
    }

    /// Read real iOS Metal pixels: dense click transients must keep their height
    /// and coverage while Continuous Scroll traverses fractional pixel offsets.
    private func verifyOverviewPixels() -> String? {
        guard let device = MTLCreateSystemDefaultDevice() else { return "No Metal device" }
        let engine = MetalWaveformEngine(device: device, synchronousPreparation: true)
        guard engine.isReady else { return engine.preparationError ?? "Pipeline unavailable" }
        let size = CGSize(width: 128, height: 128)
        let item = CGRect(x: 10, y: 10, width: 108, height: 108)
        let points: [SIMD2<Float>] = stride(from: 0, to: 8192, by: 256).flatMap { frame in
            let level: Float = frame == 256 || frame == 4096 ? 0.8 : 0.1
            return [SIMD2(Float(frame), -level), SIMD2(Float(frame + 256), level)]
        }
        let block = TimelineAudioWaveform.VertexBlock(channels: [points], start: 0, end: 8192,
            step: 256, rate: 48000, key: "ipad-overview-scroll", isPeakEnvelope: true)
        var retained: MetalWaveformEngine.SourceBuffers = [:]
        for density: Float in [1, 2] {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: Int(size.width * CGFloat(density)), height: Int(size.height * CGFloat(density)), mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else { return "Texture unavailable" }
            var totals: [Double] = []
            for phase: Float in [0, 0.1, 0.25, 0.49, 0.75, 1] {
                let stroke = MetalWaveformStroke(block: block, channel: 0, scale: SIMD2(0.001, 40),
                    translation: SIMD2(20 + phase, 64), clip: item, color: SIMD4(repeating: 1), itemRect: item)
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = texture
                pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                guard let command = engine.commandQueue?.makeCommandBuffer(),
                      engine.encode(MetalWaveformFrame(size: size, strokes: [stroke]), pass: pass,
                        command: command, density: density, retaining: &retained) else { return "Encode failed" }
                command.commit()
                command.waitUntilCompleted() // Test readback only, never in application drawing.
                guard command.status == .completed else { return "GPU command failed" }
                var pixels = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
                texture.getBytes(&pixels, bytesPerRow: texture.width * 4,
                    from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
                let x = Int(round((20 + phase) * density)), y = Int(34 * density)
                guard pixels[(y * texture.width + x) * 4 + 3] > 240 else {
                    return "Overview transient lost amplitude during scroll"
                }
                totals.append(Double(stride(from: 3, to: pixels.count, by: 4).reduce(0) { $0 + Int(pixels[$1]) }))
                guard engine.lastEncodedSegmentCount <= Int(ceil(9 * density)) else {
                    return "Overview geometry exceeds physical pixel budget"
                }
            }
            guard let highest = totals.max(), let lowest = totals.min(), highest > 0,
                  (highest - lowest) / highest < 0.001 else { return "Overview pulsates during scroll" }
        }
        return nil
    }
}
