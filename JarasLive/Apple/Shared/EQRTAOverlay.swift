import SwiftUI
import Combine

/// The analyzer redraws its own lightweight layer. EQ knobs and the response
/// curve do not rebuild when a new PCM spectrum arrives.
struct EQRTAOverlay: View {
    let target: UUID?
    @StateObject private var display = EQSpectrumDisplay()
    private let clock = Timer.publish(every: 1.0 / 20, on: .main, in: .common).autoconnect()

    var body: some View {
        Canvas { context, size in
            let input = path(display.spectrum.input, size: size)
            let output = path(display.spectrum.output, size: size)
            if let output {
                var fill = output
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()
                context.fill(fill, with: .color(JarasTheme.green.opacity(0.12)))
                context.stroke(output, with: .color(JarasTheme.green.opacity(0.75)), lineWidth: 1)
            }
            if let input { context.stroke(input, with: .color(.white.opacity(0.38)), lineWidth: 1) }
            context.draw(Text("RTA  INPUT / OUTPUT").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundColor(.white.opacity(0.5)),
                         at: CGPoint(x: size.width - 8, y: 10), anchor: .trailing)
        }.allowsHitTesting(false)
            .onReceive(clock) { _ in display.update(frames: StemAudioPlayback.shared.eqSpectrumFrames(target)) }
    }

    private func path(_ bins: [Float], size: CGSize) -> Path? {
        guard bins.count > 1, bins.contains(where: { $0 > -95.9 }) else { return nil }
        var result = Path()
        for (index, db) in bins.enumerated() {
            let point = CGPoint(x: size.width * Double(index) / Double(bins.count - 1),
                                y: size.height * (6 - Double(min(6, max(-96, db)))) / 102)
            if index == 0 { result.move(to: point) } else { result.addLine(to: point) }
        }
        return result
    }
}
