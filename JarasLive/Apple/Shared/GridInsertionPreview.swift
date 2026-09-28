import SwiftUI

/// File drags update this small overlay without invalidating timeline tiles or track layout.
@MainActor final class GridInsertionPreview: ObservableObject {
    @Published private(set) var time: Double?
    func update(_ position: Double?) {
        let next = position.flatMap { $0.isFinite ? max(0, $0) : nil }
        if time != next { time = next }
    }
}

struct GridInsertionPreviewOverlay: View {
    @ObservedObject var preview: GridInsertionPreview
    let scale: Double
    let rulerHeight: CGFloat
    let viewportHeight: CGFloat
    var body: some View {
        if let time = preview.time {
            Canvas { context, size in
                let color = Color(white: 0.9).opacity(0.6)
                let x = size.width / 2
                var head = Path()
                head.move(to: CGPoint(x: x - 4, y: rulerHeight - 7))
                head.addLine(to: CGPoint(x: x + 4, y: rulerHeight - 7))
                head.addLine(to: CGPoint(x: x, y: rulerHeight))
                head.closeSubpath()
                context.fill(head, with: .color(color))
                var line = Path()
                line.move(to: CGPoint(x: x, y: rulerHeight))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(color), lineWidth: 1)
            }
            .frame(width: 10, height: viewportHeight)
            .offset(x: time * scale - 5)
        }
    }
}
