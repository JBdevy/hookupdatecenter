import AppKit

enum HeaderProjectionProbe { static var invalidations = 0 }
_ = NSApplication.shared
let grid = GridSelectionView(frame: CGRect(x: 0, y: 0, width: 700, height: 300))
let window = NSWindow(contentRect: grid.frame, styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = grid
grid.headerHeight = 64
let id = UUID()
var item = GridSelectionItem(id: id, rect: CGRect(x: 0, y: 100, width: 10_000, height: 70),
    name: "Voz principal – Coração 🎤", duration: 100)
grid.items = [item]
func pixels(scale: Int = 1) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 700 * scale, pixelsHigh: 300 * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 700 * scale * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    context.translateBy(x: 0, y: 300); context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    grid.draw(grid.bounds)
    NSGraphicsContext.restoreGraphicsState()
    window.displayIfNeeded()
    grid.needsDisplay = false
    return Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
}
for scale in [1, 2] {
    grid.timelineOrigin = CGPoint(x: 900, y: 0)
    let reference = pixels(scale: scale)
    for frame in 1...400 {
        grid.timelineOrigin.x = 900 + CGFloat(frame) * 1.25
        precondition(!grid.invalidateHeaderProjectionIfNeeded(), "unchanged pinned headers retain backing during continuous scroll")
        precondition(pixels(scale: scale) == reference, "skipping redraw preserves actual rendered pixels at each scale")
    }
    grid.timelineOrigin.x = 1
    precondition(grid.invalidateHeaderProjectionIfNeeded(), "the entering fade grip invalidates the header backing")
    precondition(pixels(scale: scale) != reference)
    grid.timelineOrigin = CGPoint(x: 9400, y: 0)
    precondition(grid.invalidateHeaderProjectionIfNeeded(), "item right edge and fade grip entering the viewport repaint")
    _ = pixels(scale: scale)
    grid.timelineOrigin.x += 5
    precondition(grid.invalidateHeaderProjectionIfNeeded(), "visible fade grips follow every scroll frame")
    _ = pixels(scale: scale)
}
grid.timelineOrigin = CGPoint(x: 900, y: 0)
_ = pixels()
let unchanged = GridSelectionLayout(items: [item])
grid.updateLayout(unchanged, pixelsPerSecond: 1)
precondition(!grid.needsDisplay, "recreated identical metadata retains rendered content")
for change in 0..<8 {
    switch change {
    case 0: item.muted.toggle()
    case 1: item.pan = -0.35
    case 2: item.gain = 0.42
    case 3: item.phaseInverted.toggle()
    case 4: item.hasFX.toggle()
    case 5: item.fxBypassed.toggle()
    case 6: item.name = "Novo nome"
    default: item.rect.origin.y += 1
    }
    let previousInvalidations = HeaderProjectionProbe.invalidations
    grid.items = [item]
    precondition(HeaderProjectionProbe.invalidations == previousInvalidations + 1, "audible/visible control edits invalidate immediately")
    _ = pixels()
}
item.fadeIn = 20
let beforeFadeChange = HeaderProjectionProbe.invalidations
grid.items = [item]
precondition(HeaderProjectionProbe.invalidations == beforeFadeChange + 1)
let beforeFade = pixels()
grid.timelineOrigin.x += 1
precondition(grid.invalidateHeaderProjectionIfNeeded(), "fade curves intersecting the viewport follow subpixel scroll")
precondition(pixels() != beforeFade)
item.fadeIn = 0
grid.items = [item]
_ = pixels()
grid.timelineOrigin.y += 1
precondition(grid.invalidateHeaderProjectionIfNeeded(), "vertical scroll repositions row headers")
_ = pixels()
let beforeRemoval = HeaderProjectionProbe.invalidations
grid.items = []
precondition(HeaderProjectionProbe.invalidations == beforeRemoval + 1, "removing the last item clears retained header pixels")
_ = pixels()
grid.timelineOrigin.x += 100
precondition(!grid.invalidateHeaderProjectionIfNeeded(), "empty grid scroll needs no header painting")
print("GRID_HEADER_800_STABLE_SCROLL_FRAMES_IDENTICAL_PIXELS_1X_2X_FADES_CONTROLS_AND_DELETION_OK")
