private let app = NSApplication.shared
private let view = TimelineNativeGridView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
private let white = CGColor(gray: 1, alpha: 1)
private let black = CGColor(gray: 0, alpha: 1)
private func content(origin: CGPoint = .zero, primary: [CGFloat] = [40, 120], horizontal: [CGFloat] = [52.5, 112.5], bands: [TimelineNativeGridBand] = [], displayScale: CGFloat = 2) -> TimelineNativeGridBackdrop {
    TimelineNativeGridBackdrop(viewport: CGRect(origin: origin, size: view.bounds.size), rulerHeight: 30,
        displayScale: displayScale, primary: primary, bands: bands,
        background: black, primaryColor: white, horizontal: horizontal, rowColor: white)
}
private func bitmap(_ target: NSView = view) -> NSBitmapImageRep {
    let context = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 640 * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: 360)
    context.scaleBy(x: 2, y: -2)
    target.layer!.render(in: context)
    return NSBitmapImageRep(cgImage: context.makeImage()!)
}
private func brightness(_ image: NSBitmapImageRep, x: Int, y: Int) -> CGFloat {
    image.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!.redComponent
}
view.update(content())
private let initialLayers = view.layer!.sublayers!.map(ObjectIdentifier.init)
private let first = bitmap()
// The thin continuous line covers 0.5 physical pixels, starting below the ruler.
precondition(brightness(first, x: 80, y: 100) > 0.45 && brightness(first, x: 80, y: 100) < 0.55)
precondition(brightness(first, x: 80, y: 104) > 0.45, "grid line stays continuous")
precondition(brightness(first, x: 79, y: 100) < 0.1 && brightness(first, x: 81, y: 100) < 0.1)
precondition(brightness(first, x: 80, y: 20) < 0.1)
precondition(brightness(first, x: 160, y: 100) < 0.1, "The minor ruler tick has no line in the grid")
precondition(brightness(first, x: 200, y: 105) > 0.9 && brightness(first, x: 200, y: 225) > 0.9,
             "Horizontal lines run along the physical pixel at each row boundary")
precondition(brightness(first, x: 200, y: 104) < 0.1 && brightness(first, x: 200, y: 106) < 0.1,
             "Horizontal lines occupy one physical pixel")

// Large document coordinates must remain precise and bounded to the viewport.
view.update(content(origin: CGPoint(x: 1_000_000_000, y: 100), primary: [1_000_000_020], horizontal: [112.5]))
private let scrolled = bitmap()
precondition(brightness(scrolled, x: 40, y: 4) > 0.45)
precondition(brightness(scrolled, x: 40, y: 10) > 0.45, "vertical scrolling keeps the line continuous")
precondition(brightness(scrolled, x: 80, y: 100) < 0.1, "obsolete lines disappear in the next frame")
precondition(brightness(scrolled, x: 160, y: 25) > 0.9, "A scrolled separator follows its track")
for step in 0..<200 {
    view.update(content(primary: [CGFloat(step % 250) + 0.1]))
}
precondition(view.layer!.sublayers!.map(ObjectIdentifier.init) == initialLayers, "zoom retains the same native layers")
precondition(view.layer!.sublayers!.allSatisfy { $0.animationKeys()?.isEmpty != false }, "no implicit animation trails behind the input")

private let band = TimelineNativeGridBand(rect: CGRect(x: 0, y: 60, width: 320, height: 30), color: CGColor(gray: 0.5, alpha: 1))
view.update(content(primary: [], horizontal: [], bands: [band]))
let selected = bitmap()
precondition(brightness(selected, x: 200, y: 140) > 0.45)
precondition(brightness(selected, x: 200, y: 200) < 0.1)
view.update(content(primary: [], horizontal: [], bands: []))
let cleared = bitmap()
precondition(brightness(cleared, x: 200, y: 140) < 0.1)
precondition(view.layer!.sublayers!.first!.sublayers?.isEmpty != false, "cleared selections retain no unused band layers")
precondition(view.layer!.sublayers!.compactMap { $0 as? CAShapeLayer }.count == 2)
print("NATIVE_GRID_RETINA_PIXEL_ALIGNMENT_SCROLL_ZOOM_LAYER_REUSE_SELECTION_AND_CLEAR_OK")

// Repeated transport/presentation updates retain the actual CGPath objects.
view.update(content())
private let gridLayers = view.layer!.sublayers!.compactMap { $0 as? CAShapeLayer }
private let initialPrimary = gridLayers[0].path!
private let initialRows = gridLayers[1].path!
for _ in 0..<600 { view.update(content()) }
precondition(gridLayers[0].path === initialPrimary && gridLayers[1].path === initialRows,
             "Unchanged playback frames must reuse grid geometry")
// Selection colours are independent from the grid's retained paths.
view.update(content(bands: [band]))
precondition(gridLayers[0].path === initialPrimary, "Selecting a track must not rebuild grid lines")
view.update(content(displayScale: 3))
precondition(gridLayers[0].path !== initialPrimary && gridLayers[1].path !== initialRows, "A different backing scale reprojects both axes")
print("GRID_GEOMETRY_REUSED_FOR_600_UPDATES_SELECTION_AND_DPI_OK")

// The same vertical ink is mounted above item bodies by the timeline controller.
view.moveInkToForeground()
precondition(view.foregroundInk.layer?.sublayers?.count == 1)
precondition(gridLayers[0].superlayer === view.foregroundInk.layer && gridLayers[1].superlayer === view.layer)
let foregroundPath = gridLayers[0].path
for _ in 0..<600 { view.update(content(displayScale: 3)) }
precondition(gridLayers[0].path === foregroundPath, "Foreground grid retains its paths during playback")
precondition(view.foregroundInk.hitTest(.zero) == nil, "Foreground grid must not block item input")
print("GRID_FOREGROUND_REUSES_VERTICAL_INK_WITHOUT_INTERCEPTING_INPUT_OK")

// Foreground lines cross item bodies, never the pinned ruler/region headers.
view.foregroundInk.frame = view.frame
view.update(content())
let retainedForegroundPath = gridLayers[0].path
for top: CGFloat in [30, 70, 110, 30] {
    view.foregroundInk.clipBelowRuler(documentY: top)
    let image = bitmap(view.foregroundInk)
    precondition(brightness(image, x: 80, y: Int((top - 4) * 2)) < 0.1,
                 "Grid ink must not cover the pinned headers after vertical scrolling")
    precondition(brightness(image, x: 80, y: Int((top + 4) * 2)) > 0.45,
                 "Grid ink remains visible over the items below the ruler")
    precondition(gridLayers[0].path === retainedForegroundPath,
                 "Moving the pinned boundary must not rebuild the grid geometry")
    precondition(view.foregroundInk.layer?.mask?.animationKeys()?.isEmpty != false)
}
print("GRID_FOREGROUND_STARTS_BELOW_PINNED_RULER_WITHOUT_REBUILD_OR_ANIMATION_OK")
