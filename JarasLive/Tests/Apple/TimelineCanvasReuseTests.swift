import AppKit
import SwiftUI
import Darwin

private final class CanvasViewport: ObservableObject {
    @Published var y: CGFloat = 512
    @Published var revision = 0
    @Published var overlayVisible = true
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
        GridScrollView(axis: .vertical, contentWidth: size.width, contentHeight: document.height) {
            GridScrollView(axis: .horizontal, contentWidth: document.width, contentHeight: document.height) {
                ZStack(alignment: .topLeading) {
                    ViewportTimelineCanvas(visibleRect: CGRect(x: 0, y: viewport.y, width: size.width, height: size.height), identity: TimelineTileIdentity(revision: viewport.revision)) { context, _, tile in
                        background.record(tile)
                        context.fill(Path(tile), with: .color(Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1)))
                    }
                    if viewport.overlayVisible {
                    ViewportTimelineCanvas(visibleRect: CGRect(x: 0, y: viewport.y, width: size.width, height: size.height), identity: TimelineTileIdentity(revision: viewport.revision)) { context, _, tile in
                        overlay.record(tile)
                        // A transparent surface must not obscure the background;
                        // a small solid stripe crosses the fixed-band boundary.
                        context.fill(Path(CGRect(x: 30, y: 1000, width: 30, height: 70)), with: .color(Color(.sRGB, red: 0, green: 0, blue: 1, opacity: 1)))
                    }
                    }
                }.frame(width: document.width, height: document.height, alignment: .topLeading)
            }.frame(width: size.width, height: document.height)
        }.frame(width: size.width, height: size.height)
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
private func runFixture(size: CGSize, document: CGSize, nativeScroll: Bool) {
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
        precondition(distance(red, base) < 0.01, "transparent overlay bands must leave the original base grid color unchanged")
        print("TIMELINE_TRANSPARENT_OVERLAY_BAND_SEAM_PIXELS_OK bluePixels=\(bluePixels.count)")
    }
    window.close()
    print("TIMELINE_FIXED_VERTICAL_BANDS_HOSTED_GEOMETRY_AND_BODY_OK nativeScroll=\(nativeScroll) viewport=\(Int(size.width))x\(Int(size.height)) documentHeight=\(Int(document.height))")
}

let application = NSApplication.shared
setbuf(stdout, nil)
application.setActivationPolicy(.accessory)
runFixture(size: CGSize(width: 700, height: 360), document: CGSize(width: 1800, height: 5200), nativeScroll: false)
runFixture(size: CGSize(width: 700, height: 360), document: CGSize(width: 1800, height: 5200), nativeScroll: true)
runFixture(size: CGSize(width: 800, height: 1500), document: CGSize(width: 4000, height: 5300), nativeScroll: true)
precondition(retainedDrawFailures == 0, "retained band draw closures executed; fixed geometry alone did not preserve the backing drawing")
