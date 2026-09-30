import SwiftUI
import Combine

/// The analyzer redraws its own lightweight layer. EQ knobs and the response
/// curve do not rebuild when a new PCM spectrum arrives.
struct EQRTAOverlay: View {
    let target: UUID?
    var effect = "EQ"
    @StateObject private var display = EQSpectrumDisplay()
    private let clock = Timer.publish(every: 1.0 / 20, on: .main, in: .common).autoconnect()

    var body: some View {
        EQRTAPlot(levels: EQSpectrumVector(display.spectrum))
            .animation(.linear(duration: 1.0 / 20), value: display.spectrum)
            .onReceive(clock) { _ in display.update(frames: StemAudioPlayback.shared.eqSpectrumFrames(target, effect: effect)) }
    }
}

private struct EQRTAPlot: View, Animatable {
    var levels: EQSpectrumVector
    var animatableData: EQSpectrumVector { get { levels } set { levels = newValue } }
    var body: some View {
        let spectrum = levels.spectrum
        Canvas { context, size in
            let input = path(spectrum.input, size: size)
            let output = path(spectrum.output, size: size)
            if let output {
                var fill = output
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()
                context.fill(fill, with: .color(JarasTheme.green.opacity(0.12)))
                context.stroke(output, with: .color(JarasTheme.green.opacity(0.75)), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            }
            if let input { context.stroke(input, with: .color(.white.opacity(0.38)), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)) }
            context.draw(Text("RTA  INPUT / OUTPUT").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundColor(.white.opacity(0.5)),
                         at: CGPoint(x: size.width - 8, y: 10), anchor: .trailing)
        }.allowsHitTesting(false)
    }

    private func path(_ bins: [Float], size: CGSize) -> Path? {
        guard bins.count > 1, size.width > 0, size.height > 0, bins.contains(where: { $0 > -95.9 }) else { return nil }
        let levels = bins
        let step = size.width / CGFloat(levels.count - 1)
        func height(_ index: Int) -> CGFloat {
            let db = levels[index]
            return size.height * CGFloat((6 - min(6, max(-96, db))) / 102)
        }
        // Smooth the log-frequency display first, then join it with monotone
        // cubic curves. This rounds narrow stair-shaped FFT peaks without extra
        // analysis work or changing the audio or EQ response.
        func tangent(_ index: Int) -> CGFloat {
            if index == 0 { return height(1) - height(0) }
            if index == bins.count - 1 { return height(index) - height(index - 1) }
            let left = height(index) - height(index - 1)
            let right = height(index + 1) - height(index)
            guard (left > 0 && right > 0) || (left < 0 && right < 0) else { return 0 }
            return 2 * left * right / (left + right)
        }
        var result = Path()
        var previousY = height(0)
        var previousTangent = tangent(0)
        result.move(to: CGPoint(x: 0, y: previousY))
        for index in 1..<bins.count {
            let x = CGFloat(index) * step
            let y = height(index)
            let nextTangent = tangent(index)
            result.addCurve(to: CGPoint(x: x, y: y),
                            control1: CGPoint(x: x - step * 2 / 3, y: previousY + previousTangent / 3),
                            control2: CGPoint(x: x - step / 3, y: y - nextTangent / 3))
            previousY = y
            previousTangent = nextTangent
        }
        return result
    }
}
