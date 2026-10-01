import SwiftUI

/// Retains the original item geometry throughout a touch gesture. A drag that
/// comes back to its origin is still a drag and can never reposition the cursor.
struct TimelineItemTouchGesture {
    enum Action: Equatable { case move, resize(left: Bool), fade(left: Bool) }
    let item: GridSelectionItem
    let start: CGPoint
    let action: Action
    private(set) var hasDragged = false
    init(item: GridSelectionItem, start: CGPoint, fadeSide: Bool? = nil) {
        self.item = item; self.start = start
        if let side = fadeSide ?? item.fadeSide(at: start) { action = .fade(left: side) }
        else if let side = item.resizeSide(at: start) { action = .resize(left: side) }
        else { action = .move }
    }
    mutating func advance(_ translation: CGSize) {
        if hypot(translation.width, translation.height) >= 3 { hasDragged = true }
    }
    var shouldSeek: Bool {
        guard !hasDragged else { return false }
        if case .fade = action { return false }
        return true
    }
    func fadeValue(translation: CGSize) -> Double? {
        guard case let .fade(left) = action else { return nil }
        return item.draggingFade(left: left, delta: translation.width)
    }
}

/// Drawn above the waveform GPU surface, so fade curves cannot be covered by a
/// subsequently presented Metal frame. Geometry matches the macOS native input.
struct TimelineTouchFadeCurves: View {
    let item: GridSelectionItem
    var body: some View {
        Canvas { context, _ in
            guard item.editable, item.duration > 0 else { return }
            context.clip(to: Path(item.rect))
            let top = item.fadeTop, bottom = item.rect.maxY - 2
            for left in [true, false] {
                let seconds = min(item.duration, max(0, left ? item.fadeIn : item.fadeOut))
                guard seconds > 0, bottom > top else { continue }
                let width = item.rect.width * seconds / item.duration
                let x1 = left ? item.rect.minX : item.rect.maxX - width, x2 = x1 + width
                let y1 = left ? bottom : top, y2 = left ? top : bottom
                var curve = Path()
                curve.move(to: CGPoint(x: x1, y: y1))
                curve.addCurve(to: CGPoint(x: x2, y: y2), control1: CGPoint(x: x1 + width / 3, y: y1),
                               control2: CGPoint(x: x2 - width / 3, y: y2))
                var shade = curve
                shade.addLine(to: CGPoint(x: x2, y: top)); shade.addLine(to: CGPoint(x: x1, y: top)); shade.closeSubpath()
                context.fill(shade, with: .color(.black.opacity(0.25)))
                context.stroke(curve, with: .color(.white.opacity(0.95)), lineWidth: 1)
            }
        }.allowsHitTesting(false)
    }
}
