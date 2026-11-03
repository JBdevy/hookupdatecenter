// Draw the actual native grid/ruler paths through a fractional zoom sequence.
// The cursor anchor must remain stationary and neighboring lines monotonic.
_ = NSApplication.shared
private let grid = TimelineNativeGridView(frame: CGRect(x: 0, y: 0, width: 900, height: 300))
private let ruler = TimelineNativeRulerView(frame: CGRect(x: 0, y: 0, width: 900, height: 80))
func vertices(_ path: CGPath) -> [CGPoint] {
    var points: [CGPoint] = []
    path.applyWithBlock { element in
        if element.pointee.type == .moveToPoint { points.append(element.pointee.points[0]) }
    }
    return points
}
let black = CGColor(gray: 0, alpha: 1), white = CGColor(gray: 1, alpha: 1)
var measuredDrift: CGFloat = 0
for density: CGFloat in [1, 2] {
    for timelineOrigin: CGFloat in [0, 1_000_000] {
        for direction: CGFloat in [1, -1] {
            var previousNeighbor: CGFloat?
            for step in 0..<160 {
                let scale: CGFloat = 17 + direction * CGFloat(step) * 0.0017
                let anchorTime = timelineOrigin + 31.375
                let anchor = anchorTime * scale
                let offset = anchor - 400
                let tile = floor(offset / 512) * 512
                grid.update(TimelineNativeGridBackdrop(viewport: CGRect(x: tile, y: 0, width: 1200, height: 300),
                    rulerHeight: 30, displayScale: density, primary: [anchor, (anchorTime + 2) * scale],
                    secondary: [], bands: [], background: black, primaryColor: white, secondaryColor: white))
                ruler.update(TimelineNativeRuler(viewport: CGRect(x: tile, y: 0, width: 1200, height: 80),
                    displayScale: density, barTop: 50,
                    ticks: [.init(x: anchor, primary: true, text: "1.1"), .init(x: (anchorTime + 2) * scale, primary: true, text: "1.2")],
                    rows: [], background: black, lineColor: white))
                let gridPath = (grid.layer!.sublayers![1] as! CAShapeLayer).path!
                let rulerPath = (ruler.layer!.sublayers![1] as! CAShapeLayer).path!
                let g = vertices(gridPath).map { $0.x + tile - offset }
                let r = vertices(rulerPath).map { $0.x + tile - offset }
                precondition(g.count == 2 && r.count == 2)
                precondition(zip(g, r).allSatisfy { abs($0 - $1) < 0.0000001 }, "grid and ruler must share the zoom scale")
                let error = abs(g[0] - (400 + 0.5 / density))
                measuredDrift = max(measuredDrift, error)
                if !CommandLine.arguments.contains("legacy") {
                    precondition(error < 0.0000001, "The line anchored to the edit cursor drifted sideways during zoom: \(error) points")
                    if let previousNeighbor {
                        precondition((g[1] - previousNeighbor) * direction >= -0.0000001, "A neighboring line reversed during a monotonic zoom")
                    }
                }
                previousNeighbor = g[1]
            }
        }
    }
}
if CommandLine.arguments.contains("legacy") {
    precondition(measuredDrift > 0.4, "Negative control must reproduce visible subpixel drift")
    print("LEGACY_DOCUMENT_QUANTIZATION_DRIFT_REPRODUCED maxPoints=\(measuredDrift)")
} else {
    print("NATIVE_ZOOM_GRID_RULER_STATIONARY_CURSOR_MONOTONIC_NEIGHBORS_RETINA_AND_LONG_PROJECT_OK")
}
