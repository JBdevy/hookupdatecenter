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
        WaveformDisplayResult.shared.value = "PASS: UIKit pan and zoom limits synchronized; latest frame only; stable row bounds"
    }
}
