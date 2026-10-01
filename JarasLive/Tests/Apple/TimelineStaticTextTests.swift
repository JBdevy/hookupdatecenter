import SwiftUI
import AppKit

private struct RulerFixture: View {
    let cached: Bool
    let offset: CGFloat
    let displayScale: CGFloat
    let measure: (Double) -> Void
    var body: some View {
        Canvas { context, _ in
            let began = ProcessInfo.processInfo.systemUptime
            for index in 0..<100 {
                let point = CGPoint(x: CGFloat(index % 20) * 55 + offset, y: CGFloat(index / 20) * 18)
                let text = String(index * 13 + 1)
                if cached {
                    TimelineStaticText.label(text, style: .barNumber, displayScale: displayScale)?.draw(at: point, context: &context)
                } else {
                    let label = context.resolve(Text(verbatim: text).font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundColor(.white))
                    context.draw(label, at: point, anchor: .topLeading)
                }
            }
            measure((ProcessInfo.processInfo.systemUptime - began) * 1000)
        }.frame(width: 1100, height: 100)
    }
}

@main struct TimelineStaticTextTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        for scale in [1.0, 2.0] {
            let label = TimelineStaticText.label("0st  01", style: .regionIdentifier, displayScale: scale)!
            precondition(label === TimelineStaticText.label("0st  01", style: .regionIdentifier, displayScale: scale))
            precondition(label !== TimelineStaticText.label("0st  01", style: .barNumber, displayScale: scale))
            precondition(label.image.width == Int(ceil(label.size.width * scale)))
            precondition(label.image.height == Int(ceil(label.size.height * scale)))
            precondition(label.width > 0 && label.size.height <= 16)
            let pixels = label.image.dataProvider!.data! as Data
            precondition(stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 }, "cached label must contain visible glyphs")
            precondition(label !== TimelineStaticText.label("0st  02", style: .regionIdentifier, displayScale: scale))
        }
        precondition(TimelineStaticText.label("123", style: .barNumber, displayScale: 1) !== TimelineStaticText.label("123", style: .barNumber, displayScale: 2),
                     "moving the window between backing scales rebuilds text at the native resolution")
        for cached in [false, true] {
            var durations: [Double] = []
            for iteration in 0..<24 {
                let renderer = ImageRenderer(content: RulerFixture(cached: cached, offset: CGFloat(iteration % 4) * 0.25,
                    displayScale: 2, measure: { durations.append($0) }))
                renderer.scale = 2
                precondition(renderer.cgImage != nil)
            }
            let measured = durations.dropFirst(4).sorted()
            print("RULER_100_LABELS_\(cached ? "CACHED" : "SWIFTUI")_MS median=\(measured[measured.count / 2]) max=\(measured.last!)")
        }
        print("TIMELINE_STATIC_TEXT_CACHE_STYLE_BACKING_SCALE_AND_VISIBLE_GLYPHS_OK")
    }
}
