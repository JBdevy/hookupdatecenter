import AppKit

// Text rendering has its own regression suite. Removing it from both sides
// isolates the nontext control paths and checks their surrounding state.
enum GridSelectionHeaderText {
    struct Title { @inline(__always) func draw(in rect: CGRect) {} }
    static let mute = Title(), fx = Title(), activeFX = Title(), edit = Title()
    @inline(__always) static func gain(_ value: String) -> Title { Title() }
    @inline(__always) static func title(_ value: String) -> Title { Title() }
}
struct HeaderDrawing {
    let item: GridSelectionItem
    let gainLabel: String?
}
struct HeaderPixels { let viewport: CGRect }
struct PreparedHeaderProjection { let pixels: HeaderPixels; let drawings: [HeaderDrawing] }

// Frozen drawing before fixed-path retention and direct needle strokes.
// The production methods are extracted by test-grid-header-controls.sh.
enum OriginalHeaderRenderer {
    static func drawItemFades(_ item: GridSelectionItem) {
        guard item.editable, item.duration > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: item.rect).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let top = item.fadeTop, bottom = item.rect.maxY - 2
        for left in [true, false] {
            let amount = min(item.duration, max(0, left ? item.fadeIn : item.fadeOut))
            if amount > 0, bottom > top {
                let width = item.rect.width * amount / item.duration
                let x1 = left ? item.rect.minX : item.rect.maxX - width
                let x2 = x1 + width
                let y1 = left ? bottom : top, y2 = left ? top : bottom
                let curve = NSBezierPath()
                curve.move(to: CGPoint(x: x1, y: y1))
                curve.curve(to: CGPoint(x: x2, y: y2), controlPoint1: CGPoint(x: x1 + width / 3, y: y1), controlPoint2: CGPoint(x: x2 - width / 3, y: y2))
                let shade = curve.copy() as! NSBezierPath
                shade.line(to: CGPoint(x: x2, y: top)); shade.line(to: CGPoint(x: x1, y: top)); shade.close()
                NSColor.black.withAlphaComponent(0.25).setFill(); shade.fill()
                NSColor.white.withAlphaComponent(0.95).setStroke(); curve.lineWidth = 1; curve.stroke()
            }
            if let handle = item.fadeHandleRect(left) {
                NSColor.white.withAlphaComponent(0.85).setFill()
                let grip = NSBezierPath()
                grip.move(to: CGPoint(x: left ? handle.minX : handle.maxX, y: handle.minY))
                grip.line(to: CGPoint(x: left ? handle.maxX : handle.minX, y: handle.minY))
                grip.line(to: CGPoint(x: left ? handle.minX : handle.maxX, y: handle.maxY))
                grip.close(); grip.fill()
            }
        }
    }
    static func drawHeaders(_ projection: PreparedHeaderProjection) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: projection.pixels.viewport).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        for drawing in projection.drawings {
                let item = drawing.item
                if let rect = item.muteRect {
                    (item.muted ? NSColor.systemRed : NSColor.black.withAlphaComponent(0.28)).setFill(); rect.fill()
                    GridSelectionHeaderText.mute.draw(in: rect.insetBy(dx: 1, dy: 0))
                }
                if let rect = item.fxRect {
                    (item.fxBypassed ? NSColor.systemRed : NSColor.black.withAlphaComponent(0.28)).setFill(); rect.fill()
                    (item.hasFX && !item.fxBypassed ? GridSelectionHeaderText.activeFX : GridSelectionHeaderText.fx)
                        .draw(in: rect.insetBy(dx: 1, dy: 0))
                }
                if let rect = item.editRect {
                    NSColor.black.withAlphaComponent(0.28).setFill(); rect.fill()
                    GridSelectionHeaderText.edit.draw(in: rect.insetBy(dx: 1, dy: 0))
                }
                if let rect = item.gainKnobRect {
                    let center = CGPoint(x: rect.midX, y: rect.midY), radius = 4.5 * GridSelectionItem.headerScale
                    let ring = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                    NSColor.black.setFill(); ring.fill()
                    NSColor.white.setStroke(); ring.lineWidth = 1.5; ring.stroke()
                    let angle = (135 + item.gainPosition * 270) * .pi / 180
                    let needle = NSBezierPath(); needle.move(to: center)
                    needle.line(to: CGPoint(x: center.x + cos(angle) * (3.5 * GridSelectionItem.headerScale), y: center.y + sin(angle) * (3.5 * GridSelectionItem.headerScale)))
                    NSColor(calibratedRed: 0.2, green: 1, blue: 0.55, alpha: 1).setStroke(); needle.lineWidth = 2; needle.stroke()
                }
                if let rect = item.phaseRect {
                    (item.phaseInverted ? NSColor.systemYellow : NSColor.black.withAlphaComponent(0.28)).setFill(); rect.fill()
                    let center = CGPoint(x: rect.midX, y: rect.midY)
                    let path = NSBezierPath(ovalIn: CGRect(x: center.x - 3.5 * GridSelectionItem.headerScale, y: center.y - 3.5 * GridSelectionItem.headerScale, width: 7 * GridSelectionItem.headerScale, height: 7 * GridSelectionItem.headerScale))
                    path.move(to: CGPoint(x: center.x - 4.5 * GridSelectionItem.headerScale, y: center.y + 4.5 * GridSelectionItem.headerScale)); path.line(to: CGPoint(x: center.x + 4.5 * GridSelectionItem.headerScale, y: center.y - 4.5 * GridSelectionItem.headerScale))
                    (item.phaseInverted ? NSColor.black : NSColor.white).setStroke(); path.lineWidth = 1.2; path.stroke()
                }
                if let rect = item.panKnobRect {
                    let center = CGPoint(x: rect.midX, y: rect.midY), radius = 4.5 * GridSelectionItem.headerScale
                    let ring = NSBezierPath(ovalIn: CGRect(x: center.x-radius, y: center.y-radius, width: radius*2, height: radius*2))
                    NSColor.black.setFill(); ring.fill()
                    NSColor.white.setStroke(); ring.lineWidth = 1.5; ring.stroke()
                    let value = item.pan
                    let angle = (135 + (value+1)/2*270) * .pi / 180
                    let needle = NSBezierPath(); needle.move(to: center)
                    needle.line(to: CGPoint(x: center.x+cos(angle)*(3.5 * GridSelectionItem.headerScale), y: center.y+sin(angle)*(3.5 * GridSelectionItem.headerScale)))
                    NSColor(calibratedRed: 0.2, green: 1, blue: 0.55, alpha: 1).setStroke(); needle.lineWidth = 2; needle.stroke()
                }
                if let rect = item.panLabelRect {
                    GridSelectionHeaderText.gain(item.panLabel).draw(in: rect.insetBy(dx: 1, dy: 0))
                }
                if let rect = item.gainLabelRect(text: drawing.gainLabel) { GridSelectionHeaderText.gain(drawing.gainLabel ?? item.gainLabel).draw(in: rect.insetBy(dx: 1, dy: 0)) }
                let titleInset = item.headerTitleInset(gainLabel: drawing.gainLabel)
                let nameRect = CGRect(x: item.headerRect.minX + titleInset + 4, y: item.rect.minY + 1,
                                      width: max(0, item.headerRect.width - titleInset - 8), height: min(GridSelectionItem.headerHeight - 1, item.rect.height - 1))
                if nameRect.width >= 10 { GridSelectionHeaderText.title(item.name ?? "").draw(in: nameRect) }
                drawItemFades(item)
        }
    }
}

_ = NSApplication.shared
setbuf(stdout, nil)

func makeProjection(_ seed: Int, count: Int = 18) -> PreparedHeaderProjection {
    let widths: [CGFloat] = [19, 27.3, 45, 58, 76, 97, 120, 174, 200, 300, 420]
    let offsets: [CGFloat] = [0, 0.125, 0.25, 0.5, 0.75, 0.999]
    let pans = [-1.0, -0.73251, -0.01, 0, 0.234789, 0.8, 1]
    let gains = [0.0, 0.0137, 0.33, 1, 1.173495, 3.93, 15.8]
    let heights: [CGFloat] = [16, 17, 18, 24, 42, 64]
    let drawings = (0..<count).map { index -> HeaderDrawing in
        let k = index + seed
        let width = widths[k % widths.count]
        var item = GridSelectionItem(id: UUID(),
            rect: CGRect(x: CGFloat(index % 3) * 230 + offsets[k % offsets.count],
                         y: CGFloat(index % 10) * 31 + offsets[(k + 2) % offsets.count],
                         width: width, height: heights[k % heights.count]),
            gain: gains[k % gains.count], phaseInverted: k % 3 == 0,
            pan: pans[k % pans.count], name: "Item \(index)", muted: k % 4 == 0,
            hasFX: k % 2 == 0, fxBypassed: k % 7 == 0, duration: 5,
            fadeIn: k % 11 == 0 ? 0.05 : 0, fadeOut: k % 13 == 0 ? 0.02 : 0)
        if k % 9 == 0 { item.midiEditable = true }
        if k % 13 == 0 { item.editable = false; item.textEditable = true }
        let gain = item.gainLabel
        item = item.visibleLeftHeader(in: CGRect(x: 0, y: 0, width: 800, height: 360), titleWidth: 80, gainLabel: gain)
        return HeaderDrawing(item: item, gainLabel: gain)
    }
    return PreparedHeaderProjection(pixels: HeaderPixels(viewport: CGRect(x: 0, y: 0, width: 800, height: 360)), drawings: drawings)
}

func bitmap(scale: Int, flipped: Bool, projection: PreparedHeaderProjection, candidate: Bool) -> NSBitmapImageRep {
    let width = 800 * scale, height = 360 * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    if flipped { context.translateBy(x: 0, y: 360); context.scaleBy(x: 1, y: -1) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: flipped)
    if candidate { CandidateHeaderRenderer.drawHeaders(projection) }
    else { OriginalHeaderRenderer.drawHeaders(projection) }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

var cases = 0
for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
        for scale in [1, 2, 3] {
            for flipped in [false, true] {
                for seed in 0..<12 {
                    let projection = makeProjection(seed)
                    let before = bitmap(scale: scale, flipped: flipped, projection: projection, candidate: false)
                    let after = bitmap(scale: scale, flipped: flipped, projection: projection, candidate: true)
                    let n = before.bytesPerRow * before.pixelsHigh
                    precondition(Data(bytes: before.bitmapData!, count: n) == Data(bytes: after.bitmapData!, count: n),
                        "Cached controls preserve original pixels, clipping, fades and subpixel placement: \(appearance), \(scale)x, flipped=\(flipped), seed=\(seed)")
                    cases += 1
                }
            }
        }
    }
}
print("GRID_HEADER_CONTROLS_OK: \(cases) pixel-exact cases at 1x/2x/3x, light/dark, fractional origins, heights and continuous gain/pan")
