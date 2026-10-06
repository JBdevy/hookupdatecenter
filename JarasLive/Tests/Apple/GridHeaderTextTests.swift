import AppKit

_ = NSApplication.shared
func oldAttributes(centered: Bool? = nil, color: NSColor = .white) -> [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
    if let centered { paragraph.alignment = centered ? .center : .left }
    return [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: color, .paragraphStyle: paragraph]
}
func bitmap(scale: Int = 1, flipped: Bool = false, _ draw: () -> Void) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 480 * scale, pixelsHigh: 48 * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 480 * scale * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    if flipped { context.translateBy(x: 0, y: 48); context.scaleBy(x: 1, y: -1) }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: flipped)
    NSColor.black.setFill(); CGRect(x: 0, y: 0, width: 480, height: 48).fill()
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
}
let names = ["Kick", "Guitarra base com nome muito longo para caber no item",
             "Coração – ação 🎸", "Cafe\u{301} / voz", "音楽トラック 🎹", "مسار الموسيقى", ""]
var cases = 0
for name in names {
    let old = NSAttributedString(string: name, attributes: oldAttributes())
    let cached = GridSelectionHeaderText.title(name)
    precondition(cached === GridSelectionHeaderText.title(name), "repeated title measurement reuses the prepared entry")
    precondition(cached.width == old.size().width, "cache preserves AppKit metrics, including combining and multibyte text")
    for width: CGFloat in [20, 42, 58, 110, 360] {
        for left: CGFloat in [0, 150, 9500] {
            var item = GridSelectionItem(id: UUID(), rect: CGRect(x: 100, y: 30, width: 10000, height: 64), name: name, duration: 60)
            for gain in [0.0, 0.001, 1, 1.5] {
                item.gain = gain
                let viewport = CGRect(x: left, y: 0, width: width, height: 400)
                let before = item.visibleLeftHeader(in: viewport, titleWidth: old.size().width)
                let after = item.visibleLeftHeader(in: viewport, titleWidth: cached.width)
                precondition(after.headerRect == before.headerRect && after.rect == before.rect)
                precondition(after.muteRect == before.muteRect && after.fxRect == before.fxRect &&
                    after.editRect == before.editRect && after.gainKnobRect == before.gainKnobRect &&
                    after.gainLabelRect == before.gainLabelRect && after.titleInset == before.titleInset,
                    "title caching must preserve the drawn control and pointer hit regions")
                cases += 1
            }
        }
        let rect = CGRect(x: 1, y: 10, width: width, height: 13)
        for scale in [1, 2, 1] { for flipped in [false, true] {
            let expected = bitmap(scale: scale, flipped: flipped) { old.draw(in: rect) }
            for _ in 0..<2 {
                precondition(expected == bitmap(scale: scale, flipped: flipped) { cached.draw(in: rect) },
                             "cached title preserves clipping and shaping: \(name), width \(width), scale \(scale), flipped \(flipped)")
            }
        } }
    }
}
let labels: [(String, GridSelectionHeaderText.Title, Bool, NSColor)] = [
    ("M", GridSelectionHeaderText.mute, true, .white),
    ("FX", GridSelectionHeaderText.fx, true, .white),
    ("FX", GridSelectionHeaderText.activeFX, true, .systemGreen),
    ("Edit", GridSelectionHeaderText.edit, true, .white),
    ("−∞ dB", GridSelectionHeaderText.gain("−∞ dB"), false, .white),
    ("+3.5 dB", GridSelectionHeaderText.gain("+3.5 dB"), false, .white),
]
for (label, cached, centered, color) in labels {
    for width: CGFloat in [17, 20, 30, 60] {
        let rect = CGRect(x: 0, y: 10, width: width, height: 13).insetBy(dx: 1, dy: 0)
        for scale in [1, 2, 1] { for flipped in [false, true] {
            precondition(bitmap(scale: scale, flipped: flipped) { (label as NSString).draw(in: rect, withAttributes: oldAttributes(centered: centered, color: color)) } ==
                         bitmap(scale: scale, flipped: flipped) { cached.draw(in: rect) }, "prepared labels preserve original pixels: \(label), scale \(scale), flipped \(flipped)")
        } }
    }
}
for index in 0..<2000 { _ = GridSelectionHeaderText.gain(String(format: "%+.1f dB", Double(index) / 10 - 100)) }
precondition(GridSelectionHeaderText.gain("−∞ dB").string == "−∞ dB")
print("GRID_HEADER_CACHED_WIDTHS_HIT_REGIONS_AND_IDENTICAL_TEXT_PIXELS_OK cases=\(cases)")

// Measure repeated scroll drawing against the already-prepared attributed
// strings, excluding file import and first title measurement from either path.
let benchmarkNames = ["Metrônomo 156bpm Desbloqueado versão pagode.wav", "Regência Desbloqueado versão pagode.wav",
                      "Voz Desbloqueado versão pagode.wav", "Baixo Desbloqueado versão pagode.wav"]
let originals = benchmarkNames.map { NSAttributedString(string: $0, attributes: oldAttributes()) }
let benchmarkRect = CGRect(x: 1, y: 10, width: 360, height: 13)
for prepared in [false, true, true, false] {
    let start = ProcessInfo.processInfo.systemUptime
    _ = bitmap {
        for _ in 0..<1500 { for (index, name) in benchmarkNames.enumerated() {
            if prepared { GridSelectionHeaderText.title(name).draw(in: benchmarkRect) }
            else { originals[index].draw(in: benchmarkRect) }
        } }
    }
    print("GRID_HEADER_SCROLL_DRAW_BENCHMARK prepared=\(prepared) seconds=\(ProcessInfo.processInfo.systemUptime - start)")
}
