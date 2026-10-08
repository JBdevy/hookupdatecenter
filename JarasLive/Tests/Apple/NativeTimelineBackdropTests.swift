private let app = NSApplication.shared
private let view = TimelineNativeGridView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
private let white = CGColor(gray: 1, alpha: 1)
private let black = CGColor(gray: 0, alpha: 1)
private func content(origin: CGPoint = .zero, primary: [CGFloat] = [40, 120], secondary: [CGFloat] = [80], bands: [TimelineNativeGridBand] = [], displayScale: CGFloat = 2) -> TimelineNativeGridBackdrop {
    TimelineNativeGridBackdrop(viewport: CGRect(origin: origin, size: view.bounds.size), rulerHeight: 30,
        displayScale: displayScale, primary: primary, secondary: secondary, bands: bands,
        background: black, primaryColor: white, secondaryColor: CGColor(gray: 0.5, alpha: 1))
}
private func bitmap() -> NSBitmapImageRep {
    let context = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 640 * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: 360)
    context.scaleBy(x: 2, y: -2)
    view.layer!.render(in: context)
    return NSBitmapImageRep(cgImage: context.makeImage()!)
}
private func brightness(_ image: NSBitmapImageRep, x: Int, y: Int) -> CGFloat {
    image.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!.redComponent
}
view.update(content())
private let initialLayers = view.layer!.sublayers!.map(ObjectIdentifier.init)
private let first = bitmap()
// One physical-pixel line at Retina scale, starting below the ruler.
precondition(brightness(first, x: 80, y: 100) > 0.9)
precondition(brightness(first, x: 79, y: 100) < 0.1 && brightness(first, x: 81, y: 100) < 0.1)
precondition(brightness(first, x: 80, y: 20) < 0.1)
precondition(brightness(first, x: 160, y: 100) > 0.4 && brightness(first, x: 160, y: 100) < 0.6)

// Large document coordinates must remain precise and bounded to the viewport.
view.update(content(origin: CGPoint(x: 1_000_000_000, y: 100), primary: [1_000_000_020], secondary: []))
private let scrolled = bitmap()
precondition(brightness(scrolled, x: 40, y: 10) > 0.9)
precondition(brightness(scrolled, x: 80, y: 100) < 0.1, "obsolete lines disappear in the next frame")
for step in 0..<200 {
    view.update(content(primary: [CGFloat(step % 250) + 0.1], secondary: []))
}
precondition(view.layer!.sublayers!.map(ObjectIdentifier.init) == initialLayers, "zoom retains the same native layers")
precondition(view.layer!.sublayers!.allSatisfy { $0.animationKeys()?.isEmpty != false }, "no implicit animation trails behind the input")

private let band = TimelineNativeGridBand(rect: CGRect(x: 0, y: 60, width: 320, height: 30), color: CGColor(gray: 0.5, alpha: 1))
view.update(content(primary: [], secondary: [], bands: [band]))
let selected = bitmap()
precondition(brightness(selected, x: 200, y: 140) > 0.45)
precondition(brightness(selected, x: 200, y: 200) < 0.1)
view.update(content(primary: [], secondary: [], bands: []))
let cleared = bitmap()
precondition(brightness(cleared, x: 200, y: 140) < 0.1)
precondition(view.layer!.sublayers!.first!.sublayers?.isEmpty != false, "cleared selections retain no unused band layers")
private var rowFrame = content(primary: [], secondary: [])
rowFrame.horizontal = [50, 110]; rowFrame.rowColor = white
view.update(rowFrame)
private let rowPixels = bitmap()
precondition(brightness(rowPixels, x: 200, y: 100) > 0.9)
precondition(brightness(rowPixels, x: 200, y: 105) < 0.1)
private let rowLayer = view.layer!.sublayers!.last as! CAShapeLayer
private let oldPath = rowLayer.path!
rowFrame = content(origin: CGPoint(x: 4_000_000, y: 0), primary: [4_000_080], secondary: [])
rowFrame.horizontal = [50, 110]; rowFrame.rowColor = white
view.update(rowFrame)
precondition(rowLayer.path === oldPath, "horizontal movement does not rebuild track dividers")
rowFrame.horizontal = [70, 130]
view.update(rowFrame)
precondition(rowLayer.path !== oldPath, "individual track resizing updates divider geometry")
print("NATIVE_GRID_RETINA_PIXEL_ALIGNMENT_SCROLL_ZOOM_LAYER_REUSE_SELECTION_AND_CLEAR_OK")
