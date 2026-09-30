import AppKit
import SwiftUI
import Darwin

private final class CanvasViewport: ObservableObject {
    @Published var y: CGFloat = 512
    @Published var revision = 0
    @Published var overlayVisible = true
    @Published var zoom: CGFloat = 1
}
private struct SurfaceKey: Hashable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    init(_ rectangle: CGRect) {
        x = rectangle.minX; y = rectangle.minY
        width = rectangle.width; height = rectangle.height
    }
}
private final class CanvasDrawCounts {
    var calls: [SurfaceKey: Int] = [:]
    func record(_ tile: CGRect) { calls[SurfaceKey(tile), default: 0] += 1 }
}
private var surfaceBodyCounts: [SurfaceKey: Int] = [:]
private func recordSurfaceBody(_ tile: CGRect) { surfaceBodyCounts[SurfaceKey(tile), default: 0] += 1 }
private var retainedDrawFailures = 0
private struct CanvasFixture: View {
    @ObservedObject var viewport: CanvasViewport
    let document: CGSize
    let size: CGSize
    let background: CanvasDrawCounts
    let overlay: CanvasDrawCounts
    var body: some View {
        let width = max(size.width, document.width * viewport.zoom)
        GridScrollView(axis: .vertical, contentWidth: size.width, contentHeight: document.height) {
            GridScrollView(axis: .horizontal, contentWidth: width, contentHeight: document.height) {
                CanvasBands(viewport: viewport, size: size, background: background, overlay: overlay)
                    .frame(width: width, height: document.height, alignment: .topLeading)
            }.frame(width: size.width, height: document.height)
        }.frame(width: size.width, height: size.height)
    }
}
// Match the production TimelineViewportLayer: its viewport observation lives
// inside the document's hosting view, where native destination preparation can
// synchronously mount new bands without laying out the whole application.
private struct CanvasBands: View {
    @ObservedObject var viewport: CanvasViewport
    let size: CGSize
    let background: CanvasDrawCounts
    let overlay: CanvasDrawCounts
    var body: some View {
        ZStack(alignment: .topLeading) {
            ViewportTimelineCanvas(visibleRect: CGRect(x: 0, y: viewport.y, width: size.width, height: size.height), synchronized: true, identity: TimelineTileIdentity(revision: viewport.revision)) { context, _, tile in
                background.record(tile)
                context.fill(Path(tile), with: .color(Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1)))
                // Verify content placement as well as opaque coverage.
                context.fill(Path(CGRect(x: 100, y: tile.minY + 16, width: 24, height: 24)), with: .color(Color(.sRGB, red: 0, green: 1, blue: 0, opacity: 1)))
            }
            if viewport.overlayVisible {
                ViewportTimelineCanvas(visibleRect: CGRect(x: 0, y: viewport.y, width: size.width, height: size.height), identity: TimelineTileIdentity(revision: viewport.revision)) { context, _, tile in
                    overlay.record(tile)
                    // A transparent surface must not obscure the background;
                    // a small solid stripe crosses the fixed-band boundary.
                    context.fill(Path(CGRect(x: 30, y: 1000, width: 30, height: 70)), with: .color(Color(.sRGB, red: 0, green: 0, blue: 1, opacity: 1)))
                }
            }
        }
    }
}

private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
}
private func settle(_ window: NSWindow) {
    for _ in 0..<4 {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.025))
    }
}
@MainActor private func runFixture(size: CGSize, document: CGSize, nativeScroll: Bool) {
    let state = CanvasViewport(), background = CanvasDrawCounts(), overlay = CanvasDrawCounts()
    let host = NSHostingView(rootView: CanvasFixture(viewport: state, document: document, size: size, background: background, overlay: overlay))
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFront(nil)
    settle(window)
    guard let outer = descendants(host).compactMap({ $0 as? GridNativeScrollView }).first else { preconditionFailure("real native scroll hosting was not created") }
    let maximum = max(0, document.height - size.height)
    func move(to y: CGFloat) {
        let position = min(maximum, y)
        if nativeScroll { outer.contentView.scroll(to: CGPoint(x: 0, y: position)) }
        state.y = floor(position / 512) * 512
        settle(window)
    }
    move(to: 512)
    precondition(!background.calls.isEmpty && !overlay.calls.isEmpty, "real hosted Canvas draw closures must execute")
    for y: CGFloat in [1024, 1536, 2048, maximum] {
        let before = background.calls, overlayBefore = overlay.calls, bodyBefore = surfaceBodyCounts
        move(to: y)
        let common = Set(before.keys).intersection(background.calls.keys)
        precondition(!common.isEmpty, "successive vertical viewports retain fixed-band surfaces")
        let redrawn = common.filter { background.calls[$0] != before[$0] }
        let overlayRedrawn = common.filter { overlay.calls[$0] != overlayBefore[$0] }
        let rebuilt = common.filter { surfaceBodyCounts[$0] != bodyBefore[$0] }
        print("BAND_STEP nativeScroll=\(nativeScroll) y=\(Int(y)) retainedDraw=\(redrawn.count) retainedOverlayDraw=\(overlayRedrawn.count) retainedBody=\(rebuilt.count) newDraw=\(Set(background.calls.keys).subtracting(before.keys).count)")
        for key in redrawn { print("REDRAW_TILE \(key) before=\(before[key]!) after=\(background.calls[key]!)") }
        retainedDrawFailures += redrawn.count + overlayRedrawn.count
        precondition(rebuilt.isEmpty, "an unchanged fixed-band SwiftUI body must not be reevaluated while scrolling")
        precondition(background.calls.keys.allSatisfy { $0.y >= 0 && $0.y + $0.height <= document.height && $0.height <= 1024 && $0.width <= 3072 }, "all bands remain bounded at the document end")
    }
    let beforeEdit = background.calls.values.reduce(0, +)
    state.revision += 1
    settle(window)
    precondition(background.calls.values.reduce(0, +) > beforeEdit, "a structural render identity change must redraw retained surfaces")
    if nativeScroll {
        move(to: 980)
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { preconditionFailure("hosting must provide a bitmap for transparency verification") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / size.width
        func pixel(_ x: Int, _ y: Int) -> NSColor { bitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)! }
        let red = pixel(Int(10 * scale), Int(10 * scale))
        let blue = pixel(Int(40 * scale), Int(50 * scale))
        func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
            abs(a.redComponent-b.redComponent) + abs(a.greenComponent-b.greenComponent) + abs(a.blueComponent-b.blueComponent) + abs(a.alphaComponent-b.alphaComponent)
        }
        precondition(distance(red, blue) > 0.2, "the colored overlay stripe must actually render")
        let bluePixels = (0..<bitmap.pixelsHigh).filter {
            let color = pixel(Int(40 * scale), $0)
            return distance(color, blue) < 0.01
        }
        precondition(CGFloat(bluePixels.count) >= 68 * scale, "the overlay stripe crosses the 1024-point band seam without gaps")
        precondition(distance(pixel(Int(40 * scale), Int(43 * scale)), pixel(Int(40 * scale), Int(45 * scale))) < 0.01, "both sides of the 1024-point seam have the same overlay color")
        state.overlayVisible = false
        settle(window)
        let control = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: control)
        let base = control.colorAt(x: Int(10 * scale), y: Int(10 * scale))!.usingColorSpace(.sRGB)!
        let contentMarker = control.colorAt(x: Int(110 * scale), y: Int(72 * scale))!.usingColorSpace(.sRGB)!
        precondition(distance(contentMarker, base) > 0.2, "the content position marker must actually render")
        precondition(distance(red, base) < 0.01, "transparent overlay bands must leave the original base grid color unchanged")
        print("TIMELINE_TRANSPARENT_OVERLAY_BAND_SEAM_PIXELS_OK bluePixels=\(bluePixels.count)")
        for position: CGFloat in [255, 511, 767, 1023, 1535, maximum, 511, 0] {
            move(to: position)
            let scrolled = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: scrolled)
            let pixelScale = CGFloat(scrolled.pixelsHigh) / size.height
            for y in stride(from: CGFloat(8), through: size.height - 8, by: 32) {
                let color = scrolled.colorAt(x: Int(10 * pixelScale), y: Int(y * pixelScale))!.usingColorSpace(.sRGB)!
                precondition(distance(color, base) < 0.01, "continuous native scrolling must not expose blank pixels between tile publications")
            }
        }
        print("TIMELINE_NATIVE_SUBBUCKET_SCROLL_NO_BLANK_PIXELS_OK")
        let controller = SidebarScrollController()
        controller.attach(outer)
        controller.prepareScroll = { position in
            let bucket = floor(position / 512) * 512
            guard state.y != bucket else { return false }
            state.y = bucket
            return true
        }
        // Do not settle the run loop, force view display, or use cacheDisplay:
        // cacheDisplay itself mounts missing Canvas tiles and concealed the
        // original one-frame blank area during large native thumb movements.
        for requested: CGFloat in [4096, 0, 3333, 257, maximum, 1] {
            let position = min(maximum, requested)
            controller.scroll(to: position)
            let drawCount = background.calls.values.reduce(0, +)
            let immediate = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            let nativeContext = NSGraphicsContext(bitmapImageRep: immediate)!
            host.layer!.render(in: nativeContext.cgContext)
            precondition(background.calls.values.reduce(0, +) == drawCount, "capture must inspect already prepared layers without causing a Canvas render")
            let pixelScale = CGFloat(immediate.pixelsHigh) / size.height
            func currentPixel(x: CGFloat, y: CGFloat) -> NSColor {
                // CALayer's bitmap context starts at the bottom of this image.
                immediate.colorAt(x: Int(x * pixelScale), y: Int((size.height - y) * pixelScale))!.usingColorSpace(.sRGB)!
            }
            for y in stride(from: CGFloat(8), through: size.height - 8, by: 32) {
                precondition(distance(currentPixel(x: 10, y: y), base) < 0.01, "a large native scrollbar jump must prepare every visible pixel before returning")
            }
            var checkedMarkers = 0
            for band in stride(from: floor(position / 256) * 256, through: position + size.height, by: 256) {
                let markerY = band + 28 - position
                guard markerY >= 2 && markerY < size.height - 2 else { continue }
                let green = currentPixel(x: 110, y: markerY)
                precondition(distance(green, contentMarker) < 0.01, "new destination content must appear at its correct document position immediately")
                checkedMarkers += 1
            }
            precondition(checkedMarkers > 0, "every fast jump must validate actual destination content")
        }
        print("TIMELINE_NATIVE_FAST_THUMB_JUMPS_AND_REVERSALS_IMMEDIATE_PIXELS_OK")
        for scale: CGFloat in [0.005, 0.25, 2, 32, 8192, 1] {
            state.zoom = scale
            settle(window)
            let resized = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: resized)
            let color = resized.colorAt(x: Int(10 * CGFloat(resized.pixelsWide) / size.width), y: 10)!.usingColorSpace(.sRGB)!
            precondition(distance(color, base) < 0.01, "resizing cached hosting during zoom must not leave a black or stale grid")
        }
        print("TIMELINE_CACHED_RESIZE_EXTREME_ZOOM_GRID_PIXELS_OK")
    }
    window.close()
    print("TIMELINE_FIXED_VERTICAL_BANDS_HOSTED_GEOMETRY_AND_BODY_OK nativeScroll=\(nativeScroll) viewport=\(Int(size.width))x\(Int(size.height)) documentHeight=\(Int(document.height))")
}

let application = NSApplication.shared
setbuf(stdout, nil)
application.setActivationPolicy(.accessory)
MainActor.assumeIsolated {
    runFixture(size: CGSize(width: 700, height: 360), document: CGSize(width: 1800, height: 5200), nativeScroll: false)
    runFixture(size: CGSize(width: 700, height: 360), document: CGSize(width: 1800, height: 5200), nativeScroll: true)
    runFixture(size: CGSize(width: 800, height: 1500), document: CGSize(width: 4000, height: 5300), nativeScroll: true)
    precondition(retainedDrawFailures == 0, "retained band draw closures executed; fixed geometry alone did not preserve the backing drawing")
}
