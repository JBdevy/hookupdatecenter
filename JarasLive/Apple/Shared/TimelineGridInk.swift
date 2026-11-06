import SwiftUI
import QuartzCore

/// One retained drawing per mounted layer, bounded by the visible grid. Colours
/// and playback updates do not rebuild geometry; scrolling/zooming still do.
final class TimelineGridPathCache {
    private struct Geometry: Equatable {
        let positions: [CGFloat]
        let origin: CGFloat
        let top: CGFloat
        let bottom: CGFloat
        let inset: CGFloat
    }
    private var geometry: Geometry?
    private var retained: CGPath?
    private(set) var builds = 0

    func path(positions: [CGFloat], origin: CGFloat, top: CGFloat, bottom: CGFloat, inset: CGFloat = 0) -> CGPath {
        let next = Geometry(positions: positions, origin: origin, top: top, bottom: bottom, inset: inset)
        if next == geometry, let retained { return retained }
        let path = CGMutablePath()
        if bottom > top {
            for position in positions {
                let x = position - origin + inset
                guard x.isFinite, top.isFinite, bottom.isFinite else { continue }
                path.move(to: CGPoint(x: x, y: top))
                path.addLine(to: CGPoint(x: x, y: bottom))
            }
        }
        let result = path.copy()!
        geometry = next; retained = result; builds += 1
        return result
    }
}

#if os(iOS)
import UIKit

/// The iPad grid keeps its native layers when transport/meters publish. Only
/// the visible line coordinates change on zoom; no full-height Canvas is built.
struct TimelineRetainedGrid: UIViewRepresentable {
    let primary: [CGFloat]
    let secondary: [CGFloat]
    let primaryColor: Color
    let secondaryColor: Color
    let displayScale: CGFloat
    var strokeWidth: CGFloat = 0.75
    var dashed = true

    func makeUIView(context: Context) -> TimelineRetainedGridView { TimelineRetainedGridView() }
    func updateUIView(_ view: TimelineRetainedGridView, context: Context) {
        view.update(primary: primary, secondary: secondary,
            primaryColor: UIColor(primaryColor).cgColor, secondaryColor: UIColor(secondaryColor).cgColor,
            scale: displayScale, strokeWidth: strokeWidth, dashed: dashed)
    }
}

final class TimelineRetainedGridView: UIView {
    private let primaryLayer = CAShapeLayer()
    private let secondaryLayer = CAShapeLayer()
    private let primaryInk = TimelineGridPathCache()
    private let secondaryInk = TimelineGridPathCache()
    private var primary: [CGFloat] = []
    private var secondary: [CGFloat] = []
    private var scale: CGFloat = 1
    private var strokeWidth: CGFloat = 0.75

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false; isUserInteractionEnabled = false; clipsToBounds = true
        for shape in [primaryLayer, secondaryLayer] {
            shape.fillColor = nil; shape.lineDashPattern = [1, 3]
            layer.addSublayer(shape)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(primary: [CGFloat], secondary: [CGFloat], primaryColor: CGColor, secondaryColor: CGColor, scale: CGFloat,
                strokeWidth: CGFloat = 0.75, dashed: Bool = true) {
        self.primary = primary; self.secondary = secondary
        self.scale = scale.isFinite ? max(1, scale) : 1
        self.strokeWidth = strokeWidth
        let disabled = CATransaction.disableActions()
        CATransaction.setDisableActions(true)
        defer { CATransaction.setDisableActions(disabled) }
        primaryLayer.strokeColor = primaryColor; secondaryLayer.strokeColor = secondaryColor
        for shape in [primaryLayer, secondaryLayer] { shape.lineDashPattern = dashed ? [1, 3] : nil }
        updateGeometry()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        updateGeometry()
    }
    private func updateGeometry() {
        let disabled = CATransaction.disableActions()
        CATransaction.setDisableActions(true)
        defer { CATransaction.setDisableActions(disabled) }
        for (shape, ink, positions) in [(primaryLayer, primaryInk, primary), (secondaryLayer, secondaryInk, secondary)] {
            shape.frame = bounds; shape.contentsScale = scale; shape.lineWidth = strokeWidth / scale
            let path = ink.path(positions: positions, origin: 0, top: 0, bottom: bounds.height)
            if shape.path !== path { shape.path = path }
        }
    }
}
#endif
