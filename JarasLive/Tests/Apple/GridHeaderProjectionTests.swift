import AppKit

enum HeaderProjectionProbe { static var invalidations = 0; static var titleBuilds = 0; static var projections = 0 }
_ = NSApplication.shared
let grid = GridSelectionView(frame: CGRect(x: 0, y: 0, width: 700, height: 300))
let window = NSWindow(contentRect: grid.frame, styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = grid
grid.headerHeight = 64
let id = UUID()
var item = GridSelectionItem(id: id, rect: CGRect(x: 0, y: 100, width: 10_000, height: 70),
    name: "Voz principal – Coração 🎤", duration: 100)
item.hasSelectableMediaHeader = true
item.blackTitle = true
item.selectedBlackTitle = true
grid.updateLayout(GridSelectionLayout(items: [item]), pixelsPerSecond: 30)
func pixels(scale: Int = 1, dirty: CGRect? = nil, previous: Data? = nil) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 700 * scale, pixelsHigh: 300 * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 700 * scale * 4, bitsPerPixel: 32)!
    if let previous { previous.copyBytes(to: bitmap.bitmapData!, count: previous.count) }
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    context.translateBy(x: 0, y: 300); context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    if let dirty { context.clip(to: dirty); context.clear(dirty) }
    grid.draw(dirty ?? grid.bounds)
    NSGraphicsContext.restoreGraphicsState()
    window.displayIfNeeded()
    grid.needsDisplay = false
    return Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
}
let deselectedPixels = pixels()
let selectionInvalidations = HeaderProjectionProbe.invalidations
grid.updateSelection([id])
precondition(HeaderProjectionProbe.invalidations > selectionInvalidations, "Selecting an item must invalidate its native header immediately")
let selectedPixels = pixels()
let column = 680
func alphaAt(_ pixels: Data, _ row: Int) -> UInt8 { pixels[(700 * row + column) * 4 + 3] }
precondition(alphaAt(selectedPixels, 107) == 255 && alphaAt(deselectedPixels, 107) == 0,
             "Selection fills the entire visible header, including beyond the title")
precondition(alphaAt(selectedPixels, 135) == alphaAt(deselectedPixels, 135),
             "Selection stripe leaves the waveform body untouched")
precondition(alphaAt(deselectedPixels, 116) > 0 && alphaAt(deselectedPixels, 115) == 0,
             "One narrow line separates the header from the waveform across the whole item")
grid.updateSelection([])
precondition(pixels() == deselectedPixels, "Clearing selection must restore the original header")
print("GRID_HEADER_SELECTION_INVALIDATION_AND_RESTORE_OK")

// AppKit can already have a narrow dirty strip when it restores the horizontal
// scroll position. That strip cannot replace titles across the retained backing.
grid.timelineOrigin.x = 240
let partial = pixels(dirty: CGRect(x: 688, y: 76, width: 10, height: 200), previous: deselectedPixels)
precondition(partial == deselectedPixels, "The dirty strip did not include the old title")
precondition(grid.invalidateHeaderProjectionIfNeeded(),
    "A partial paint at the restored origin must not certify stale titles across the retained backing")
let restoredWithoutZoom = pixels()
grid.timelineOrigin.x = 0
_ = pixels()
precondition(restoredWithoutZoom != deselectedPixels)
print("GRID_HEADER_PARTIAL_REPAINT_DURING_RESTORE_OK")

for scale in [1, 2] {
    grid.timelineOrigin = CGPoint(x: 900, y: 0)
    let reference = pixels(scale: scale)
    for frame in 1...400 {
        grid.timelineOrigin.x = 900 + CGFloat(frame) * 1.25
        precondition(!grid.invalidateHeaderProjectionIfNeeded(), "offscreen item controls do not invalidate the backing")
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
grid.timelineOrigin = .zero
_ = pixels()
let unchanged = GridSelectionLayout(items: [item])
grid.updateLayout(unchanged, pixelsPerSecond: 30)
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
    grid.updateLayout(GridSelectionLayout(items: [item]), pixelsPerSecond: 30)
    precondition(HeaderProjectionProbe.invalidations == previousInvalidations + 1, "audible/visible control edits invalidate immediately")
    _ = pixels()
}
item.fadeIn = 20
let beforeFadeChange = HeaderProjectionProbe.invalidations
grid.updateLayout(GridSelectionLayout(items: [item]), pixelsPerSecond: 30)
precondition(HeaderProjectionProbe.invalidations == beforeFadeChange + 1)
let beforeFade = pixels()
grid.timelineOrigin.x += 1
precondition(grid.invalidateHeaderProjectionIfNeeded(), "fade curves intersecting the viewport follow subpixel scroll")
precondition(pixels() != beforeFade)
item.fadeIn = 0
grid.updateLayout(GridSelectionLayout(items: [item]), pixelsPerSecond: 30)
_ = pixels()
grid.timelineOrigin.y += 1
precondition(grid.invalidateHeaderProjectionIfNeeded(), "vertical scroll repositions row headers")
_ = pixels()
let beforeRemoval = HeaderProjectionProbe.invalidations
grid.updateLayout(GridSelectionLayout(items: []), pixelsPerSecond: 30)
precondition(HeaderProjectionProbe.invalidations == beforeRemoval + 1, "removing the last item clears retained header pixels")
_ = pixels()
grid.timelineOrigin.x += 100
precondition(!grid.invalidateHeaderProjectionIfNeeded(), "empty grid scroll needs no header painting")
print("GRID_HEADER_800_STABLE_SCROLL_FRAMES_IDENTICAL_PIXELS_1X_2X_FADES_CONTROLS_AND_DELETION_OK")

// An offscreen recording name does not jump to the visible edge as the
// recording grows, including across hosted-canvas bucket boundaries.
grid.updateLayout(GridSelectionLayout(items: []), pixelsPerSecond: 30)
grid.timelineOrigin = CGPoint(x: 900, y: 0)
var take = GridSelectionItem(id: UUID(), rect: CGRect(x: 0, y: 100, width: 1250, height: 70),
    editable: false, resizable: false, movable: false, contextActions: false, name: "Voz gravando")
for scale in [1, 2] {
    grid.timelineOrigin.x = 900
    take.rect.size.width = 1250
    grid.updateLayout(GridSelectionLayout(items: []), pixelsPerSecond: 30)
        grid.recordingHeaders = [take]
    let reference = pixels(scale: scale)
    for frame in 1...1000 {
        grid.timelineOrigin.x = 900 + CGFloat(frame) * 1.25
        take.rect.size.width = grid.timelineOrigin.x + 350
        grid.updateLayout(GridSelectionLayout(items: []), pixelsPerSecond: 30)
        grid.recordingHeaders = [take]
        precondition(pixels(scale: scale) == reference, "offscreen recording name must remain outside the viewport")
    }
}
let recordingPixels = pixels()
grid.recordingHeaders = []
precondition(pixels() != recordingPixels, "finishing a take clears its temporary title")
print("RECORDING_HEADER_2000_GROWING_SCROLL_FRAMES_STABLE")

// Playback follow translates the viewport without moving the item header.
item.fadeIn = 0; item.fadeOut = 0
let threshold = GridSelectionItem.followingHeaderMinimumScale
let headerLayout = GridSelectionLayout(items: [item])
func following(_ active: Bool) {
    NotificationCenter.default.post(name: Notification.Name("CatLiveTimelineFollowPresentation"),
        object: window, userInfo: ["active": active])
}
grid.timelineOrigin = CGPoint(x: 0, y: 0)
grid.updateLayout(headerLayout, pixelsPerSecond: threshold - 0.01)
let lowVisible = pixels()
following(true)
precondition(pixels() == lowVisible, "Distant zoom keeps names visible during continuous follow")
grid.updateLayout(headerLayout, pixelsPerSecond: threshold)
let highVisible = pixels()
following(false)
precondition(pixels() == highVisible, "Stopping does not alter the item header")
following(true)
precondition(pixels() == highVisible, "Continuous follow keeps controls at the item start")
grid.updateLayout(headerLayout, pixelsPerSecond: threshold - 0.01)
precondition(pixels() == lowVisible, "Zooming below the reference restores names while playback continues")
following(false)
grid.timelineOrigin.x = 100
let lowScrolled = pixels()
precondition(lowScrolled != lowVisible, "Distant headers move with their original item start")
grid.updateLayout(headerLayout, pixelsPerSecond: threshold)
let fixedReference = pixels()
grid.timelineOrigin.x = 900
precondition(pixels() != fixedReference, "Closer scrolling carries the item controls past the viewport edge")
print("GRID_HEADER_REFERENCE_ZOOM_FIXED_START_FOLLOW_STOP_MANUAL_AND_RESUME_OK")

// More simultaneously visible names than the shared bitmap cache can retain.
// Keep their positions inside the viewport throughout rapid zoom reversals.
grid.frame = CGRect(x: 0, y: 0, width: 2048, height: 800)
grid.timelineOrigin = .zero; grid.headerHeight = 40
grid.updateSelection([])
let denseItems = (0..<512).map { index in
    GridSelectionItem(id: UUID(), rect: CGRect(x: CGFloat(index % 32) * 60, y: 50 + CGFloat(index / 32) * 42, width: 59, height: 38),
        name: "\(index) – Nome de stem longo e único para o show completo 🎸 – gravação original")
}
let denseLayout = GridSelectionLayout(items: denseItems)
grid.updateLayout(denseLayout, pixelsPerSecond: 1)
let denseBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2048, pixelsHigh: 800,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 2048 * 4, bitsPerPixel: 32)!
func drawDenseHeaders() {
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: denseBitmap)!.cgContext
    context.translateBy(x: 0, y: 800); context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    grid.draw(grid.bounds)
    NSGraphicsContext.restoreGraphicsState()
    grid.needsDisplay = false
}
drawDenseHeaders()
let initialShapes = HeaderProjectionProbe.titleBuilds
let initialProjections = HeaderProjectionProbe.projections
// Stopped transport sends no live recording headers, including on zoom frames.
for _ in 0..<20 { grid.recordingHeaders = [] }
precondition(HeaderProjectionProbe.projections == initialProjections,
    "Empty recording updates must not rebuild every visible header")
let beganDenseZoom = ProcessInfo.processInfo.systemUptime
for frame in 0..<30 {
    let before = HeaderProjectionProbe.projections
    for sample in 0..<3 {
        grid.updateLayout(denseLayout, pixelsPerSecond: 1 + CGFloat((frame * 3 + sample) % 17) * 0.001)
    }
    precondition(HeaderProjectionProbe.projections == before,
        "Zoom geometry and anchor updates must coalesce before preparing header pixels")
    drawDenseHeaders()
    precondition(HeaderProjectionProbe.projections == before + 1, "One header projection per painted frame")
}
let denseZoomElapsed = (ProcessInfo.processInfo.systemUptime - beganDenseZoom) * 1000
precondition(HeaderProjectionProbe.titleBuilds == initialShapes,
    "Visible titles must retain their shaped text even when they exceed the global bitmap cache budget")
print("DENSE_ZOOM_512_TITLES_30_FRAMES_NO_RESHAPING_SINGLE_PROJECTION_OK \(Int(denseZoomElapsed))ms")
grid.updateLayout(GridSelectionLayout(items: []), pixelsPerSecond: 30); drawDenseHeaders()

final class HeaderTestDocument: NSView { override var isFlipped: Bool { true } }
let outer = NSScrollView(frame: CGRect(x: 0, y: 0, width: 700, height: 300))
let tileColumn = HeaderTestDocument(frame: CGRect(x: 0, y: 0, width: 700, height: 900))
let inner = NSScrollView(frame: tileColumn.bounds)
let document = HeaderTestDocument(frame: CGRect(x: 0, y: 0, width: 2100, height: 900))
window.contentView = outer
outer.documentView = tileColumn
tileColumn.addSubview(inner)
inner.documentView = document
grid.removeFromSuperview()
document.addSubview(grid)
grid.headerDocument = document
grid.frame = CGRect(x: 128, y: 0, width: 828, height: 300)
grid.headerHeight = 64
grid.updateLayout(GridSelectionLayout(items: [
    GridSelectionItem(id: UUID(), rect: CGRect(x: 245, y: 100, width: 220, height: 66), name: "14-PIANO LIVE-grudado")
]), pixelsPerSecond: 1)
inner.contentView.scroll(to: CGPoint(x: 128, y: 0))
grid.observeHeaderScroll()
_ = pixels()
let tileProjections = HeaderProjectionProbe.projections
for x in 129...245 {
    inner.contentView.scroll(to: CGPoint(x: x, y: 0))
    precondition(!grid.invalidateHeaderProjectionIfNeeded(), "Scrolling within the title tile keeps its document pixels")
}
precondition(HeaderProjectionProbe.projections == tileProjections, "Small horizontal pans must reuse the title projection")
let firstTileInk = pixels()
inner.contentView.scroll(to: CGPoint(x: 270, y: 0))
grid.setFrameOrigin(CGPoint(x: 256, y: 0))
grid.headerTileMoved()
precondition(pixels() != firstTileInk, "Changing the title tile places the ink at its new document-relative position")
print("GRID_HEADER_DOCUMENT_TILE_117_PANS_REUSE_ONE_PROJECTION_OK")
