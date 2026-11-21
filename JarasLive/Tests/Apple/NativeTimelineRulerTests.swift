private let app = NSApplication.shared
private let view = TimelineNativeRulerView(frame: CGRect(x: 0, y: 0, width: 400, height: 80))
private func content(origin: CGFloat = 0, ticks: [TimelineNativeRuler.Tick]) -> TimelineNativeRuler {
    TimelineNativeRuler(viewport: CGRect(x: origin, y: 0, width: 400, height: 80), displayScale: 2,
        barTop: 48, numberLaneHeight: 16, ticks: ticks, rows: [16.5, 32.5, 48.5, 64.5, 79.5], background: CGColor(gray: 0, alpha: 1),
        lineColor: CGColor(gray: 0.25, alpha: 1))
}
private func bitmap() -> NSBitmapImageRep {
    let ctx = CGContext(data: nil, width: 800, height: 160, bitsPerComponent: 8, bytesPerRow: 3200,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: 160); ctx.scaleBy(x: 2, y: -2)
    view.layer!.render(in: ctx)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!)
}
view.update(content(ticks: [.init(x: 40, primary: true, text: "1.1"), .init(x: 200, primary: false, text: "")]))
let initial = view.layer!.sublayers!.map(ObjectIdentifier.init)
let first = bitmap()
func whiteLevel(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
    let pixel = image.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    return min(pixel.redComponent, pixel.greenComponent, pixel.blueComponent)
}
precondition(whiteLevel(first, 80, 152) > 0.8 && whiteLevel(first, 79, 152) < 0.1 && whiteLevel(first, 81, 152) < 0.1,
             "Retina ruler ticks remain one physical pixel")
precondition(whiteLevel(first, 400, 145) > 0.8 && whiteLevel(first, 400, 141) < 0.1,
             "Subdivisions span half of the 16-point tick lane")
precondition(whiteLevel(first, 80, 138) > 0.8 && whiteLevel(first, 400, 138) < 0.1,
             "Major ticks remain taller when the vertical grid is hidden")
precondition((86..<120).contains { x in (104..<130).contains { whiteLevel(first, x, $0) > 0.5 } },
             "cached label image draws above the bottom-aligned ticks")
let label = view.layer!.sublayers!.last!
precondition(label.frame.minY >= 48 && label.frame.maxY <= 64,
             "The larger number fits in the lane dedicated to labels")
precondition(label.frame.height > TimelineStaticText.label("1.1", style: .barNumber, displayScale: 2)!.size.height,
             "The timeline numbers use a larger font than the compact labels")
let image = label.contents as! CGImage
for i in 0..<100 {
    view.update(content(origin: 1_000_000_000, ticks: [.init(x: 1_000_000_010 + CGFloat(i), primary: true, text: "1.1")]))
}
precondition(view.layer!.sublayers!.map(ObjectIdentifier.init) == initial, "zoom moves existing layers")
precondition(label.contents as! CGImage === image, "label bitmap remains cached through zoom")
precondition(abs(label.frame.minX - 111.25) < 0.001, "large timeline coordinates preserve subpixel alignment")
precondition(view.layer!.sublayers!.allSatisfy { $0.animationKeys()?.isEmpty != false }, "no implicit motion behind the cursor")
view.update(content(ticks: []))
precondition(view.layer!.sublayers!.count == 3, "stale labels are removed")
let empty = bitmap()
precondition(whiteLevel(empty, 80, 152) < 0.1 && whiteLevel(empty, 400, 155) < 0.1, "stale ticks disappear")
print("NATIVE_RULER_RETINA_TICKS_LABEL_CACHE_LAYER_REUSE_LARGE_COORDINATES_AND_CLEAR_OK")

private let retainedFrame = content(ticks: [.init(x: 25, primary: true, text: "2.1")])
view.update(retainedFrame)
let retainedTickLayer = view.layer!.sublayers!.first { $0.name == "timelineTicks" } as! CAShapeLayer
let retainedTickPath = retainedTickLayer.path!
let retainedLabel = view.layer!.sublayers!.last!
for _ in 0..<600 { view.update(retainedFrame) }
precondition(retainedTickLayer.path === retainedTickPath, "Playback updates must retain ruler geometry")
precondition(view.layer!.sublayers!.last === retainedLabel, "Playback updates must retain ruler labels")
view.update(content(ticks: [.init(x: 25, primary: false, text: "2.2")]))
precondition(retainedTickLayer.path !== retainedTickPath, "Tempo/subdivision changes must replace tick geometry")
print("RULER_GEOMETRY_REUSED_FOR_600_UPDATES_AND_INVALIDATED_FOR_EDITS_OK")

private let numbered = TimelineNativeRuler(viewport: CGRect(x: 0, y: 0, width: 400, height: 80), displayScale: 2,
    barTop: 48, numberLaneHeight: 16,
    ticks: [.init(x: 40, primary: true, text: "13"), .init(x: 60, primary: true, text: ""),
            .init(x: 70, primary: false, text: "")],
    rows: [], background: CGColor(gray: 0, alpha: 1), lineColor: CGColor(gray: 0.25, alpha: 1),
    gridColor: CGColor(gray: 0.4, alpha: 1))
view.update(numbered)
let grid = view.layer!.sublayers!.first { $0.name == "timelinePrimaryLines" } as! CAShapeLayer
var gridStarts: [CGPoint] = []
grid.path!.applyWithBlock { element in
    if element.pointee.type == .moveToPoint { gridStarts.append(element.pointee.points[0]) }
}
precondition(gridStarts == [CGPoint(x: 40.25, y: 48), CGPoint(x: 60.25, y: 64)],
    "Only grid lines with numbers extend into the number lane")
precondition(retainedTickLayer.path!.boundingBoxOfPath.minX == 70.25 &&
             retainedTickLayer.path!.boundingBoxOfPath.maxX == 70.25,
    "The ruler draws white ticks only where there is no vertical grid line")
print("RULER_NUMBERED_VERTICAL_LINES_AND_UNDUPLICATED_TICKS_OK")
