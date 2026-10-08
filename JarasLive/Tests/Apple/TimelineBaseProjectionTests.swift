// Uses the actual controller projection blocks, real tick model and native
// renderers. The omitted controller responsibilities continue on every scroll.
private let markerLaneHeight: CGFloat = 16
private let tempoLaneHeight: CGFloat = 16
private struct ProjectionFixtureRows {
    var offsets: [CGFloat] = [0, 44, 88]
    var totalHeight: CGFloat = 132
    var baseHeight: CGFloat = 44
}
private struct ProjectionFixtureContent {
    var extent: Double = 1_000_000
    var contentHeight: CGFloat = 700
    var layoutWidth: CGFloat = 2_000_000
    var rulerHeight: CGFloat = 71
    var viewportSize = CGSize(width: 320, height: 100)
    var rows = ProjectionFixtureRows()
    var regionLanes = 1
    var sections = [TimelineTempoSection(start: 0, end: 1_000_000, bpm: 120, beats: 4, unit: 4, timebase: .free)]
    var divisions = 4
    var bands = [TimelineNativeGridBand(rect: CGRect(x: 0, y: 120, width: 100, height: 40), color: CGColor(gray: 0.3, alpha: 0.2))]
}
private struct ProjectionFixtureStyle {
    var gridlines = true
    var displayScale: CGFloat = 2
    var background = CGColor(gray: 0.05, alpha: 1)
    var primary = CGColor(gray: 0.3, alpha: 1)
    var secondary = CGColor(gray: 0.2, alpha: 0.85)
    var row = CGColor(gray: 0.4, alpha: 0.8)
    var panel = CGColor(gray: 0.1, alpha: 1)
    var headerLine = CGColor(gray: 0.5, alpha: 1)
}
private final class ProjectionFixtureHeader {
    var calls = 0
    func project(scale: CGFloat, viewport: CGRect, layoutWidth: CGFloat, displayScale: CGFloat) { calls += 1 }
}
private final class ProjectionFixtureController {
    let backdrop = TimelineNativeGridView()
    let ruler = TimelineNativeRulerView()
    let header = ProjectionFixtureHeader()
    var zoom = 0.1203
    var pixelsPerSecond: CGFloat { zoom * 10 }
    var value = ProjectionFixtureContent()
    var style = ProjectionFixtureStyle()
PRODUCTION_PROJECTION_STATE
    func contentChanged() { revision &+= 1 }
    func project(_ viewport: CGRect) {
        let value = value, style = style
        let nativeBounds = viewport, left = viewport.minX
        let width = value.extent * pixelsPerSecond
PRODUCTION_TILE_PROJECTION
    }
}
private func pixels(_ view: NSView, scale: CGFloat) -> Data {
    let w = max(1, Int(ceil(view.frame.width * scale))), h = max(1, Int(ceil(view.frame.height * scale)))
    let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: CGFloat(h)); context.scaleBy(x: scale, y: -scale)
    view.layer!.render(in: context)
    return Data(bytes: context.data!, count: h * context.bytesPerRow)
}
_ = NSApplication.shared
for scale: CGFloat in [1, 2] {
    let controller = ProjectionFixtureController()
    controller.style.displayScale = scale
    var viewport = CGRect(x: 25, y: 0, width: 320, height: 100)
    controller.project(viewport)
    let initialBackdrop = controller.backdrop.fixtureUpdates, initialRuler = controller.ruler.fixtureUpdates
    precondition(initialBackdrop == 1 && initialRuler == 1, "the first projection builds both native drawings")
    let tickBuilds = TimelineTimeRuler.fixtureTickBuilds
    let backdropLayers = controller.backdrop.layer!.sublayers!.map(ObjectIdentifier.init)
    let rulerLayers = controller.ruler.layer!.sublayers!.map(ObjectIdentifier.init)
    for offset in stride(from: CGFloat(25), through: 125, by: 0.25) {
        viewport.origin.x = offset; controller.project(viewport)
    }
    precondition(controller.backdrop.fixtureUpdates == initialBackdrop && controller.ruler.fixtureUpdates == initialRuler,
                 "continuous scroll inside prepared coverage must reuse both native drawings")
    precondition(TimelineTimeRuler.fixtureTickBuilds == tickBuilds,
                 "reuse happens before constructing musical ticks, strings or paths")
    precondition(controller.header.calls == 402, "unrelated header/input projection continues receiving each live viewport")
    precondition(controller.backdrop.layer!.sublayers!.map(ObjectIdentifier.init) == backdropLayers &&
                 controller.ruler.layer!.sublayers!.map(ObjectIdentifier.init) == rulerLayers,
                 "in-bucket scroll keeps the retained layers")
    func matchesFresh(_ label: String) {
        let fresh = ProjectionFixtureController()
        fresh.zoom = controller.zoom; fresh.value = controller.value; fresh.style = controller.style
        fresh.project(viewport)
        precondition(controller.backdrop.frame == fresh.backdrop.frame && controller.ruler.frame == fresh.ruler.frame,
                     "coverage matches an uncached projection: \(label)")
        precondition(pixels(controller.backdrop, scale: scale) == pixels(fresh.backdrop, scale: scale),
                     "grid pixels match an uncached projection: \(label)")
        precondition(pixels(controller.ruler, scale: scale) == pixels(fresh.ruler, scale: scale),
                     "ruler ticks, labels and rows match an uncached projection: \(label)")
    }
    matchesFresh("continuous scroll")
    viewport.origin.y = 600
    controller.project(viewport)
    precondition(controller.backdrop.fixtureUpdates == initialBackdrop + 1 && controller.ruler.fixtureUpdates == initialRuler,
                 "vertical coverage invalidates only the backdrop, keeping the pinned ruler: \(controller.backdrop.fixtureUpdates)/\(controller.ruler.fixtureUpdates), initial \(initialBackdrop)/\(initialRuler), frame \(controller.backdrop.frame)")
    matchesFresh("vertical coverage")
    viewport.origin.x = 1900
    controller.project(viewport)
    precondition(controller.ruler.fixtureUpdates == initialRuler + 1, "new horizontal coverage rebuilds the ruler before exposure")
    matchesFresh("horizontal coverage")
    let beforeZoom = controller.ruler.fixtureUpdates
    controller.zoom *= 1.1; controller.project(viewport)
    precondition(controller.ruler.fixtureUpdates == beforeZoom + 1, "zoom always reprojects unchanged tile geometry")
    matchesFresh("zoom")
    controller.value.sections = [TimelineTempoSection(start: 0, end: 1_000_000, bpm: 87, beats: 7, unit: 8, timebase: .free)]
    controller.value.divisions = 8
    controller.contentChanged(); controller.project(viewport)
    matchesFresh("tempo and divisions")
    controller.style.gridlines = false; controller.style.background = CGColor(gray: 0.15, alpha: 1)
    controller.style.panel = CGColor(gray: 0.2, alpha: 1)
    controller.contentChanged(); controller.project(viewport)
    matchesFresh("grid visibility and palette")
    controller.value.regionLanes = 0; controller.value.rulerHeight = 55
    controller.value.rows.offsets = []; controller.value.rows.totalHeight = 0
    controller.value.contentHeight = 100; controller.value.bands = []
    viewport.origin.y = 0
    controller.contentChanged(); controller.project(viewport)
    matchesFresh("deleted regions and rows")
    controller.style.displayScale = scale == 1 ? 2 : 1
    controller.contentChanged(); controller.project(viewport)
    matchesFresh("backing scale")
    precondition((controller.backdrop.layer!.sublayers! + controller.ruler.layer!.sublayers!).allSatisfy { $0.animationKeys()?.isEmpty != false },
                 "cache invalidation never introduces implicit animation")
}
print("NATIVE_BASE_REUSES_TILES_BEFORE_TICK_BUILD_AND_INVALIDATES_COVERAGE_ZOOM_CONTENT_STYLE_RETINA_PIXELS_OK")
