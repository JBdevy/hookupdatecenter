private let app = NSApplication.shared
private let view = TimelineNativeRulerView(frame: CGRect(x: 0, y: 0, width: 400, height: 80))
private func content(origin: CGFloat = 0, ticks: [TimelineNativeRuler.Tick]) -> TimelineNativeRuler {
    TimelineNativeRuler(viewport: CGRect(x: origin, y: 0, width: 400, height: 80), displayScale: 2,
        barTop: 50, ticks: ticks, rows: [16.5, 32.5, 50.5, 79.5], background: CGColor(gray: 0, alpha: 1),
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
func green(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
    image.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!.greenComponent
}
precondition(green(first, 80, 105) > 0.8 && green(first, 79, 105) < 0.1 && green(first, 81, 105) < 0.1,
             "Retina ruler ticks remain one physical pixel")
precondition(green(first, 400, 104) > 0.8 && green(first, 400, 110) < 0.1,
             "secondary ticks retain their shorter height")
precondition((86..<120).contains { x in (104..<130).contains { green(first, x, $0) > 0.5 } },
             "cached label image draws alongside its tick")
let label = view.layer!.sublayers!.last!
let image = label.contents as! CGImage
for i in 0..<100 {
    view.update(content(origin: 1_000_000_000, ticks: [.init(x: 1_000_000_010 + CGFloat(i), primary: true, text: "1.1")]))
}
precondition(view.layer!.sublayers!.map(ObjectIdentifier.init) == initial, "zoom moves existing layers")
precondition(label.contents as! CGImage === image, "label bitmap remains cached through zoom")
precondition(abs(label.frame.minX - 111.25) < 0.001, "large timeline coordinates preserve subpixel alignment")
precondition(view.layer!.sublayers!.allSatisfy { $0.animationKeys()?.isEmpty != false }, "no implicit motion behind the cursor")
view.update(content(ticks: []))
precondition(view.layer!.sublayers!.count == 2, "stale labels are removed")
let empty = bitmap()
precondition(green(empty, 80, 105) < 0.1 && green(empty, 400, 104) < 0.1, "stale ticks disappear")
print("NATIVE_RULER_RETINA_TICKS_LABEL_CACHE_LAYER_REUSE_LARGE_COORDINATES_AND_CLEAR_OK")
