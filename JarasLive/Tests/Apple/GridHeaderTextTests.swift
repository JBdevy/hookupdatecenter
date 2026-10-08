import AppKit

_ = NSApplication.shared
enum GridHeaderRasterProbe { static var count = 0 }
func oldAttributes(centered: Bool? = nil, color: NSColor = .white) -> [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
    if let centered { paragraph.alignment = centered ? .center : .left }
    return [.font: NSFont.systemFont(ofSize: GridSelectionItem.headerFontSize, weight: .semibold),
            .foregroundColor: color, .paragraphStyle: paragraph]
}
struct HeaderRaster {
    let bytes: Data
    let width: Int
    let height: Int
    var extent: CGRect {
        var left = width, right = 0, top = height, bottom = 0
        for y in 0..<height { for x in 0..<width where bytes[(y * width + x) * 4 + 3] != 0 {
            left = min(left, x); right = max(right, x + 1); top = min(top, y); bottom = max(bottom, y + 1)
        } }
        return right > left ? CGRect(x: left, y: top, width: right - left, height: bottom - top) : .zero
    }
}
func bitmap(scale: Int, flipped: Bool, _ draw: () -> Void) -> HeaderRaster {
    let width = 480 * scale, height = 48 * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    if flipped { context.translateBy(x: 0, y: 48); context.scaleBy(x: 1, y: -1) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: flipped)
    draw(); NSGraphicsContext.restoreGraphicsState()
    return HeaderRaster(bytes: Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh),
                        width: width, height: height)
}
// Frozen AppKit raster path from before prepared CTLine truncation. The complete
// LTR title uses its natural width; bidi/multiline and narrow text use the exact
// destination width, including fractional CGLayer extents.
func originalLayerDraw(_ text: NSAttributedString, in rect: CGRect, natural: Bool) {
    let graphics = NSGraphicsContext.current!, context = graphics.cgContext
    let transform = context.ctm, flipped = graphics.isFlipped
    let scale = CGSize(width: hypot(transform.a, transform.b), height: hypot(transform.c, transform.d))
    let naturalWidth = ceil(text.size().width) + 4
    let fits = natural && rect.width >= naturalWidth
    let size = CGSize(width: fits ? naturalWidth : rect.width, height: rect.height)
    let layer = CGLayer(context, size: CGSize(width: size.width * scale.width, height: size.height * scale.height), auxiliaryInfo: nil)!
    let drawing = layer.context!
    drawing.scaleBy(x: scale.width, y: scale.height)
    if flipped { drawing.translateBy(x: 0, y: rect.height); drawing.scaleBy(x: 1, y: -1) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: drawing, flipped: flipped)
    text.draw(in: CGRect(origin: .zero, size: size)); NSGraphicsContext.restoreGraphicsState()
    context.saveGState()
    if fits { context.clip(to: rect) }
    if flipped {
        context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
        context.draw(layer, in: CGRect(origin: .zero, size: size))
    } else { context.draw(layer, in: CGRect(origin: rect.origin, size: size)) }
    context.restoreGState()
}
let names = ["Kick", "Metrônomo 156bpm Desbloqueado versão pagode.wav", "Regência Desbloqueado versão pagode.wav",
    "Coração – ação 🎸", "Cafe\u{301} / voz", "音楽トラック 🎹", "🎸 Voz 🎼 Música", "👩🏽‍🎤 Família 👨‍👩‍👧‍👦 Ação",
    "Voz / مسار", "אבג Music", "First\nSecond", "One\tTwo", ""]
let fallback = Set(["Voz / مسار", "אבג Music", "First\nSecond", "One\tTwo", ""])
let widths: [CGFloat] = [10, 20, 29.75, 42.125, 58, 110, 200.25, 360, 420]
var cases = 0, exact = 0
for name in names {
    let original = NSAttributedString(string: name, attributes: oldAttributes())
    let cached = GridSelectionHeaderText.title(name)
    precondition(cached === GridSelectionHeaderText.title(name) && cached.string == name,
        "repeated names retain the same prepared title without modifying text or composed characters")
    precondition(cached.width == original.size().width, "AppKit item/header layout metrics remain unchanged")
    for width in widths {
        for scale in [1, 2] { for flipped in [false, true] {
            let rect = CGRect(x: 4, y: 7, width: width, height: 17)
            let before = bitmap(scale: scale, flipped: flipped) { originalLayerDraw(original, in: rect, natural: !fallback.contains(name)) }
            let after = bitmap(scale: scale, flipped: flipped) { cached.draw(in: rect) }
            cases += 1; if before.bytes == after.bytes { exact += 1 }
            if fallback.contains(name) || width >= ceil(cached.width) + 4 {
                precondition(before.bytes == after.bytes,
                    "bidi/multiline fallback and complete titles preserve exact AppKit pixels: \(name), \(width), \(scale), \(flipped)")
            }
            if !before.extent.isEmpty {
                precondition(!after.extent.isEmpty, "a shortened LTR title retains visible text or the ellipsis")
            }
            if !after.extent.isEmpty {
                precondition(after.extent.minX >= CGFloat(4 * scale - 1) &&
                    after.extent.maxX <= CGFloat(4 * scale) + ceil(width * CGFloat(scale)) + 1,
                    "text and color emoji must not escape the header horizontally at fractional/retina widths")
            }
        } }
    }
    for left: CGFloat in [0, 150, 9500] { for gain in [0.0, 0.001, 1, 1.5] {
        var item = GridSelectionItem(id: UUID(), rect: CGRect(x: 100, y: 30, width: 10000, height: 64), name: name, duration: 60)
        item.gain = gain
        let viewport = CGRect(x: left, y: 0, width: 360, height: 400)
        let before = item.visibleLeftHeader(in: viewport, titleWidth: original.size().width)
        let after = item.visibleLeftHeader(in: viewport, titleWidth: cached.width)
        precondition(before.headerRect == after.headerRect && before.rect == after.rect &&
            before.muteRect == after.muteRect && before.fxRect == after.fxRect && before.editRect == after.editRect &&
            before.gainKnobRect == after.gainKnobRect && before.gainLabelRect == after.gainLabelRect && before.titleInset == after.titleInset,
            "title preparation never changes control geometry or pointer targets")
    } }
}
let labels: [(String, GridSelectionHeaderText.Title, Bool, NSColor)] = [
    ("M", GridSelectionHeaderText.mute, true, .white), ("FX", GridSelectionHeaderText.fx, true, .white),
    ("FX", GridSelectionHeaderText.activeFX, true, .systemGreen), ("Edit", GridSelectionHeaderText.edit, true, .white),
    ("−∞ dB", GridSelectionHeaderText.gain("−∞ dB"), false, .white), ("+3.5 dB", GridSelectionHeaderText.gain("+3.5 dB"), false, .white),
]
for (label, cached, centered, color) in labels {
    for width: CGFloat in [17, 20, 30, 60] { for scale in [1, 2] { for flipped in [false, true] {
        let rect = CGRect(x: 0, y: 10, width: width, height: GridSelectionItem.headerHeight).insetBy(dx: 1, dy: 0)
        let expected = bitmap(scale: scale, flipped: flipped) {
            (label as NSString).draw(in: rect, withAttributes: oldAttributes(centered: centered, color: color))
        }
        precondition(expected.bytes == bitmap(scale: scale, flipped: flipped) { cached.draw(in: rect) }.bytes,
            "control labels retain exact AppKit pixels: \(label)")
    } } }
}
for scale in [1, 2] { for flipped in [false, true] {
    let cached = GridSelectionHeaderText.title("Repeated Coração 🎸")
    let naturalWidth = ceil(cached.width) + 4
    let began = GridHeaderRasterProbe.count
    var first: Data?
    for frame in 0..<60 {
        let wide = CGRect(x: 1, y: 10, width: naturalWidth + CGFloat(frame) * 0.125, height: GridSelectionItem.headerHeight)
        let narrow = CGRect(x: 220, y: 10, width: 32, height: GridSelectionItem.headerHeight)
        let rendered = bitmap(scale: scale, flipped: flipped) { cached.draw(in: wide); cached.draw(in: narrow) }.bytes
        if let first { precondition(rendered == first, "stable text coverage reuses identical cached pixels") }
        else { first = rendered }
    }
    precondition(GridHeaderRasterProbe.count - began == 2,
        "sixty complete widths and their narrow duplicates rasterize only two layers per scale/flip")
} }
print("GRID_HEADER_TEXT_OK: \(cases) text cases, \(exact) exact AppKit results, Unicode/fallback/retina/fractional clipping, control hit regions and layer reuse")

// A tiny zoom step often keeps exactly the same shortened glyphs. Reusing that
// raster must preserve a fresh draw's pixels without allocating per pixel step.
let stableName = "Regência / teste de largura contínua 🎸 voz.wav"
let stableAttributes = oldAttributes()
let stableText = NSAttributedString(string: stableName, attributes: stableAttributes)
let stableLine = CTLineCreateWithAttributedString(stableText)
let stableToken = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: stableAttributes))
func truncated(_ width: CGFloat) -> CTLine {
    CTLineCreateTruncatedLine(stableLine, Double(width), .end, stableToken) ?? stableToken
}
let stableWidth = (40...180).map { CGFloat($0) }.first { start in
    let line = truncated(start)
    let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    return ink.maxX < start - 1 && (1..<60).allSatisfy { CFEqual(line, truncated(start + CGFloat($0) * 0.01)) }
}!
for scale in [1, 2, 3] { for flipped in [false, true] {
    let retained = GridSelectionHeaderText.Title(stableText, prepareTitle: true)
    var retainedRasterCount = 0
    for frame in 0..<60 {
        let rect = CGRect(x: 4.25, y: 7.5, width: stableWidth + CGFloat(frame) * 0.01, height: 17)
        let count = GridHeaderRasterProbe.count
        let actual = bitmap(scale: scale, flipped: flipped) { retained.draw(in: rect) }
        retainedRasterCount += GridHeaderRasterProbe.count - count
        let fresh = GridSelectionHeaderText.Title(stableText, prepareTitle: true)
        let expected = bitmap(scale: scale, flipped: flipped) { fresh.draw(in: rect) }
        precondition(actual.bytes == expected.bytes, "retaining identical truncated glyphs preserves a fresh drawing at each exact width")
    }
    precondition(retainedRasterCount == 1, "sixty fractional zoom widths with unchanged visible glyphs need only one raster")
    let changedWidth = stableWidth + 30
    precondition(!CFEqual(truncated(stableWidth), truncated(changedWidth)), "the regression fixture must cross a glyph boundary")
    let count = GridHeaderRasterProbe.count
    _ = bitmap(scale: scale, flipped: flipped) {
        retained.draw(in: CGRect(x: 4.25, y: 7.5, width: changedWidth, height: 17))
    }
    precondition(GridHeaderRasterProbe.count == count + 1, "new visible glyphs replace the raster immediately")
} }
print("GRID_HEADER_GLYPH_CACHE_OK: 360 changing widths, fresh-pixel equivalence and glyph-boundary invalidation at 1x/2x/3x")
