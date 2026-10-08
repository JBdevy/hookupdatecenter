import SwiftUI

#if CATLIVE_RENDER_DIAGNOSTICS
/// Compiled only for controlled component-cost experiments. Release builds
/// contain no command-line bypass and always render every component.
enum TimelineRenderDiagnosticBypass {
    private static let components: Set<String> = {
        let prefix = "--catlive-render-bypass="
        let value = ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }
        return Set((value.map { String($0.dropFirst(prefix.count)) } ?? "").split(separator: ",").map(String.init))
    }()
    static func contains(_ component: String) -> Bool { components.contains("all") || components.contains(component) }
}
#endif

@MainActor final class TimelineAreaSelection: ObservableObject {
    struct Range: Equatable { let song: UUID; let start: Double; let end: Double }
    static let shared = TimelineAreaSelection()
    @Published private(set) var range: Range?
    func update(song: UUID, from: Double, to: Double) {
        guard from.isFinite, to.isFinite else { return }
        let start = max(0, min(from, to)), end = max(0, max(from, to))
        let next = end > start ? Range(song: song, start: start, end: end) : nil
        if range != next { range = next }
    }
    func clear() { if range != nil { range = nil } }
}

struct GridSelectionItem {
    static let headerScale: CGFloat = 1.3
    static let headerHeight: CGFloat = 17
    static let headerFontSize: CGFloat = (9 * headerScale).rounded()
    static let bodyInset: CGFloat = headerHeight + 1
    let id: UUID
    var rect: CGRect
    var gain: Double = 1
    var phaseInverted = false
    var pan: Double = 0
    var editable = true
    var resizable = true
    var movable = true
    var contextActions = true
    var audioExportable = true
    var midiEditable = false
    var textEditable = false
    var name: String? = nil
    var muted = false
    var hasFX = false
    var fxBypassed = false
    var duration: Double = 0
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var visibleHeader: CGRect? = nil
    // Track/lane identity survives row-height changes. The immutable item and
    // horizontal index are reused; only the row projection changes.
    var trackIndex: Int? = nil
    var laneIndex: Int = 0
    var headerRect: CGRect { visibleHeader ?? rect }
    private var controlStart: CGFloat { headerRect.minX + 2 * Self.headerScale }
    var muteRect: CGRect? { editable && headerRect.width >= 21 * Self.headerScale ? CGRect(x: controlStart, y: rect.minY, width: 17 * Self.headerScale, height: min(Self.headerHeight, rect.height)) : nil }
    var fxRect: CGRect? { editable && !midiEditable && headerRect.width >= 41 * Self.headerScale ? CGRect(x: controlStart + 18 * Self.headerScale, y: rect.minY, width: 20 * Self.headerScale, height: min(Self.headerHeight, rect.height)) : nil }
    var gainKnobRect: CGRect? { editable && headerRect.width >= (midiEditable ? 57 : 134) * Self.headerScale ? CGRect(x: controlStart + (midiEditable ? 39 : 115) * Self.headerScale, y: rect.minY, width: 15 * Self.headerScale, height: min(Self.headerHeight, rect.height)) : nil }
    var phaseRect: CGRect? { editable && !midiEditable && headerRect.width >= 57 * Self.headerScale ? CGRect(x: controlStart + 39 * Self.headerScale, y: rect.minY, width: 15 * Self.headerScale, height: min(Self.headerHeight, rect.height)) : nil }
    var panKnobRect: CGRect? { editable && !midiEditable && headerRect.width >= 74 * Self.headerScale ? CGRect(x: controlStart + 55 * Self.headerScale, y: rect.minY, width: 15 * Self.headerScale, height: min(Self.headerHeight, rect.height)) : nil }
    var panLabel: String {
        let value = pan.isFinite ? min(1, max(-1, pan)) : 0
        let percent = Int((abs(value) * 100).rounded())
        return percent == 0 ? "Center" : "\(value < 0 ? "L" : "R")-\(percent)%"
    }
    var panLabelRect: CGRect? {
        guard let knob = panKnobRect, headerRect.maxX - knob.maxX >= 45 * Self.headerScale else { return nil }
        // Reserve the same width for every value so adjusting pan never moves volume.
        return CGRect(x: knob.maxX + Self.headerScale, y: rect.minY, width: 43 * Self.headerScale, height: min(Self.headerHeight, rect.height))
    }
    var panPosition: Double { (min(1, max(-1, pan)) + 1) / 2 }
    func draggingPan(by delta: CGFloat) -> Double { min(1, max(-1, pan - Double(delta) / 60)) }
    var gainLabel: String { gain <= 0 ? "−∞ dB" : String(format: "%+.1f dB", 20 * log10(gain)) }
    var gainLabelRect: CGRect? { gainLabelRect(text: nil) }
    func gainLabelRect(text: String?) -> CGRect? {
        guard let knob = gainKnobRect else { return nil }
        let width = ceil(CGFloat((text ?? gainLabel).count) * 5.5 * Self.headerScale) + 8 * Self.headerScale
        guard headerRect.maxX - knob.maxX >= width + 3 * Self.headerScale else { return nil }
        return CGRect(x: knob.maxX + Self.headerScale, y: rect.minY, width: width, height: min(Self.headerHeight, rect.height))
    }
    var editRect: CGRect? { textEditable && headerRect.width >= 33 * Self.headerScale ? CGRect(x: controlStart, y: rect.minY, width: 30 * Self.headerScale, height: min(Self.headerHeight, rect.height)) : nil }
    var titleInset: CGFloat { headerTitleInset(gainLabel: nil) }
    func headerTitleInset(gainLabel: String?) -> CGFloat {
        let rightEdge: CGFloat
        if let label = gainLabelRect(text: gainLabel) { rightEdge = label.maxX }
        else if let knob = gainKnobRect { rightEdge = knob.maxX }
        else if let label = panLabelRect { rightEdge = label.maxX }
        else if let knob = panKnobRect ?? phaseRect { rightEdge = knob.maxX }
        else if let fx = fxRect { rightEdge = fx.maxX }
        else if let mute = muteRect { rightEdge = mute.maxX }
        else if let edit = editRect { rightEdge = edit.maxX }
        else { return 2 }
        return rightEdge - headerRect.minX + 1
    }
    func visibleLeftHeader(in viewport: CGRect, titleWidth: CGFloat, gainLabel: String? = nil) -> Self {
        var item = self
        let left = max(rect.minX, viewport.minX), right = min(rect.maxX, viewport.maxX)
        let visibleWidth = max(0, right - left)
        item.visibleHeader = CGRect(x: left, y: rect.minY, width: visibleWidth, height: min(Self.headerHeight, rect.height))
        let width = min(visibleWidth, item.headerTitleInset(gainLabel: gainLabel) + titleWidth + 12 * Self.headerScale)
        item.visibleHeader = CGRect(x: left, y: rect.minY, width: width, height: min(Self.headerHeight, rect.height))
        return item
    }
    var fadeTop: CGFloat { min(rect.maxY, rect.minY + Self.bodyInset) }
    func fadeHandleRect(_ left: Bool) -> CGRect? {
        guard editable, !midiEditable, duration > 0, rect.width >= 20, rect.maxY - fadeTop >= 7 else { return nil }
        let amount = min(duration, max(0, left ? fadeIn : fadeOut)) / duration
        let x = left ? rect.minX + amount * rect.width : rect.maxX - amount * rect.width
        return CGRect(x: min(rect.maxX - 7, max(rect.minX, x - 3.5)), y: fadeTop, width: 7, height: 7)
    }
    /// Exact geometry for the two curves and grips, kept separately from
    /// header text/controls. A zero-length fade paints only its seven-point grip.
    func fadeDrawingRects(in viewport: CGRect) -> [CGRect?] {
        guard editable, duration > 0 else { return [] }
        let visible = viewport.insetBy(dx: -2, dy: -2)
        var result: [CGRect?] = []
        result.reserveCapacity(4)
        for left in [true, false] {
            let amount = min(duration, max(0, left ? fadeIn : fadeOut))
            var curve: CGRect?
            if amount > 0, rect.maxY - 2 > fadeTop {
                let width = rect.width * amount / duration
                let bounds = CGRect(x: left ? rect.minX : rect.maxX - width, y: fadeTop,
                    width: width, height: rect.maxY - 2 - fadeTop)
                if bounds.intersects(visible) { curve = bounds }
            }
            result.append(curve)
            let grip = fadeHandleRect(left)
            result.append(grip.flatMap { $0.intersects(visible) ? $0 : nil })
        }
        return result
    }
    func fadeSide(at point: CGPoint) -> Bool? {
        let left = fadeHandleRect(true)?.contains(point) == true
        let right = fadeHandleRect(false)?.contains(point) == true
        if left && right { return point.y < fadeTop + 3.5 }
        return left ? true : right ? false : nil
    }
    func draggingFade(left: Bool, delta: CGFloat) -> Double {
        min(duration, max(0, (left ? fadeIn : fadeOut) + Double(delta) * (left ? 1 : -1) * duration / max(1, rect.width)))
    }
    func resizeSide(at point: CGPoint) -> Bool? {
        guard resizable, point.y >= rect.minY, point.y < rect.maxY else { return nil }
        let tolerance = min(10, max(2, rect.width / 2))
        let left = abs(point.x - rect.minX), right = abs(point.x - rect.maxX)
        guard min(left, right) <= tolerance else { return nil }
        return left <= right
    }
    var gainPosition: Double { max(0, min(1, (20 * log10(max(0.000001, gain)) + 60) / 84)) }
    func draggingGain(by delta: CGFloat) -> Double {
        let position = max(0, min(1, gainPosition - Double(delta) / 120))
        return position == 0 ? 0 : pow(10, (position * 84 - 60) / 20)
    }
}

/// Immutable item metadata and spatial index. Horizontal time coordinates are
/// projected only for viewport/hit-test candidates, so zoom never rebuilds the
/// index or allocates one new item record for every clip in the project.
final class GridSelectionLayout {
    let items: [GridSelectionItem]
    let timeCoordinates: Bool
    private let ids: [UUID: Int]
    private struct Row {
        let minY: CGFloat
        let maxY: CGFloat
        let indices: [Int]
        let starts: [CGFloat]
        let maximumEnds: [CGFloat]
    }
    private let rows: [Row]
    private let rowMaximumEnds: [CGFloat]
    private struct RowProjection {
        let offsets: [CGFloat]
        let laneHeights: [CGFloat]
        let top: CGFloat
        func rectangle(_ item: GridSelectionItem) -> CGRect {
            guard let track = item.trackIndex, offsets.indices.contains(track), laneHeights.indices.contains(track) else { return item.rect }
            var rect = item.rect
            rect.origin.y = top + offsets[track] + CGFloat(item.laneIndex) * laneHeights[track] + 3
            rect.size.height = max(0, laneHeights[track] - 6)
            return rect
        }
    }
    private let rowProjection: RowProjection?

    init(items: [GridSelectionItem], timeCoordinates: Bool = false) {
        self.items = items; self.timeCoordinates = timeCoordinates
        rowProjection = nil
        ids = Dictionary(items.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let groups = Dictionary(grouping: items.indices, by: { items[$0].rect.minY })
        rows = groups.map { y, indices in
            let ordered = indices.sorted {
                let left = items[$0].rect.minX, right = items[$1].rect.minX
                return left == right ? $0 < $1 : left < right
            }
            var maximum = -CGFloat.infinity
            let ends = ordered.map { index in
                maximum = max(maximum, items[index].rect.maxX)
                return maximum
            }
            return Row(minY: y, maxY: indices.map { items[$0].rect.maxY }.max() ?? y,
                       indices: ordered, starts: ordered.map { items[$0].rect.minX }, maximumEnds: ends)
        }.sorted { $0.minY < $1.minY }
        var maximum = -CGFloat.infinity
        rowMaximumEnds = rows.map { row in
            maximum = max(maximum, row.maxY)
            return maximum
        }
    }
    /// Height changes update one small record per lane, never clone/sort every
    /// clip or rebuild the ID dictionary and horizontal interval index.
    func projectingRows(offsets: [CGFloat], laneHeights: [CGFloat], top: CGFloat) -> GridSelectionLayout {
        GridSelectionLayout(projecting: self, projection: RowProjection(offsets: offsets, laneHeights: laneHeights, top: top))
    }
    private init(projecting original: GridSelectionLayout, projection: RowProjection) {
        items = original.items; timeCoordinates = original.timeCoordinates; ids = original.ids
        rowProjection = projection
        rows = original.rows.map { row in
            let rect = projection.rectangle(original.items[row.indices[0]])
            return Row(minY: rect.minY, maxY: rect.maxY, indices: row.indices,
                       starts: row.starts, maximumEnds: row.maximumEnds)
        }
        var maximum = -CGFloat.infinity
        rowMaximumEnds = rows.map { row in
            maximum = max(maximum, row.maxY)
            return maximum
        }
    }
    func item(id: UUID, pixelsPerSecond: CGFloat) -> GridSelectionItem? {
        ids[id].map { projectedItem(at: $0, pixelsPerSecond: pixelsPerSecond) }
    }
    func projectedItem(at index: Int, pixelsPerSecond: CGFloat) -> GridSelectionItem {
        var item = items[index]
        if let rowProjection { item.rect = rowProjection.rectangle(item) }
        if timeCoordinates {
            item.rect.origin.x = item.rect.minX * pixelsPerSecond + 1
            item.rect.size.width = max(2, item.rect.width * pixelsPerSecond - 2)
        }
        return item
    }
    /// Candidates retain the original per-row paint/hit order even when clips
    /// overlap or their storage order differs from their timeline positions.
    func candidates(in rect: CGRect, pixelsPerSecond: CGFloat) -> [Int] {
        guard !rows.isEmpty, pixelsPerSecond > 0, pixelsPerSecond.isFinite else { return [] }
        // Include the fixed item inset and minimum two-point clip width.
        let left = timeCoordinates ? (rect.minX - 3) / pixelsPerSecond : rect.minX
        let right = timeCoordinates ? (rect.maxX + 3) / pixelsPerSecond : rect.maxX
        var result: [Int] = []
        var rowIndex = Self.lowerBound(rowMaximumEnds, rect.minY)
        while rowIndex < rows.count, rows[rowIndex].minY <= rect.maxY {
            let row = rows[rowIndex]
            if row.maxY >= rect.minY {
                var index = Self.lowerBound(row.maximumEnds, left)
                var matching: [Int] = []
                while index < row.indices.count, row.starts[index] <= right {
                    let itemIndex = row.indices[index]
                    if items[itemIndex].rect.maxX >= left { matching.append(itemIndex) }
                    index += 1
                }
                result.append(contentsOf: matching.sorted())
            }
            rowIndex += 1
        }
        return result
    }
    private static func lowerBound(_ values: [CGFloat], _ value: CGFloat) -> Int {
        var low = 0, high = values.count
        while low < high {
            let middle = (low + high) / 2
            if values[middle] < value { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
#if os(macOS)
import AppKit
import CoreText

/// Keep AppKit metrics and fallback layout, reusing the prepared Core Graphics layer
/// during continuous scroll and zoom. Complete left-aligned text keeps a fixed
/// width; shortened titles reuse their last identical glyph layout, independent
/// of fractional changes in available width. Aligned/fallback labels retain
/// their exact drawing size.
enum GridSelectionHeaderText {
    final class Title {
        let text: NSAttributedString
        let width: CGFloat
        var string: String { text.string }
        private struct Rendering {
            let layer: CGLayer
            let size: CGSize
            let scale: CGSize
            let flipped: Bool
            let shapedLine: CTLine?
        }
        private var rendered: Rendering?
        private var complete: Rendering?
        private var truncatedWidth: CGFloat?
        private var truncatedLine: CTLine?
        private let completeWidth: CGFloat?
        private struct ShapedTitle {
            let line: CTLine
            let ellipsis: CTLine
            let baseline: CGFloat
        }
        private let shapedTitle: ShapedTitle?
        init(_ text: NSAttributedString, prepareTitle: Bool = false) {
            self.text = text; width = text.size().width
            let paragraph = text.length > 0 ? text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil
            let alignment = paragraph?.alignment ?? .natural
            let singleLine = text.string.rangeOfCharacter(from: .newlines.union(CharacterSet(charactersIn: "\t"))) == nil
            if singleLine, alignment == .left || alignment == .natural, paragraph?.baseWritingDirection != .rightToLeft {
                let line = CTLineCreateWithAttributedString(text)
                let runs = CTLineGetGlyphRuns(line) as! [CTRun]
                // Natural alignment of bidirectional text can depend on the
                // destination width. Preserve AppKit's exact layout for it.
                let leftToRight = !runs.contains { CTRunGetStatus($0).contains(.rightToLeft) }
                completeWidth = leftToRight ? ceil(width) + 4 : nil
                if prepareTitle, leftToRight, text.length > 0 {
                    var ascent: CGFloat = 0
                    CTLineGetTypographicBounds(line, &ascent, nil, nil)
                    let token = NSAttributedString(string: "…", attributes: text.attributes(at: 0, effectiveRange: nil))
                    shapedTitle = ShapedTitle(line: line, ellipsis: CTLineCreateWithAttributedString(token), baseline: ceil(ascent))
                } else { shapedTitle = nil }
            } else { completeWidth = nil; shapedTitle = nil }
        }
        func draw(in rect: CGRect) {
            guard rect.width > 0, rect.height > 0, let graphics = NSGraphicsContext.current else { return }
            let context = graphics.cgContext, flipped = graphics.isFlipped
            let transform = context.ctm
            let scale = CGSize(width: hypot(transform.a, transform.b), height: hypot(transform.c, transform.d))
            let fits = completeWidth.map { rect.width >= $0 } ?? false
            let shapedLine: CTLine?
            if !fits, let shapedTitle {
                if truncatedWidth != rect.width {
                    truncatedLine = CTLineCreateTruncatedLine(shapedTitle.line, Double(rect.width), .end, shapedTitle.ellipsis)
                        ?? shapedTitle.ellipsis
                    truncatedWidth = rect.width
                }
                shapedLine = truncatedLine
            } else { shapedLine = nil }
            // Several successive zoom widths contain exactly the same glyphs.
            // Retain their raster at its ink width and clip at the live item
            // edge instead of creating a new CGLayer for each fractional width.
            var rendering = fits ? complete : rendered
            let sameShape: Bool
            if let shapedLine, let previous = rendering?.shapedLine { sameShape = CFEqual(shapedLine, previous) }
            else { sameShape = shapedLine == nil && rendering?.shapedLine == nil }
            let rasterWidth: CGFloat
            if shapedLine != nil, sameShape, let rendering {
                rasterWidth = rendering.size.width
            } else if let shapedLine {
                let ink = CTLineGetBoundsWithOptions(shapedLine, .useGlyphPathBounds)
                rasterWidth = max(1, ceil(max(ink.maxX, CGFloat(CTLineGetTypographicBounds(shapedLine, nil, nil, nil)))) + 2)
            } else { rasterWidth = fits ? completeWidth! : rect.width }
            let size = CGSize(width: rasterWidth, height: rect.height)
            if rendering == nil || !sameShape || rendering?.size != size || rendering?.scale != scale || rendering?.flipped != flipped {
                let pixels = CGSize(width: size.width * scale.width, height: size.height * scale.height)
                guard let layer = CGLayer(context, size: pixels, auxiliaryInfo: nil), let drawing = layer.context else {
                    text.draw(in: rect); return
                }
                drawing.scaleBy(x: scale.width, y: scale.height)
                if flipped { drawing.translateBy(x: 0, y: rect.height); drawing.scaleBy(x: 1, y: -1) }
                if let line = shapedLine, let shapedTitle {
                    // Zoom changes the available width, not the shaped glyphs.
                    // Truncate the prepared line instead of invoking AppKit's
                    // full paragraph/typesetter path for each fractional width.
                    drawing.saveGState()
                    if flipped { drawing.translateBy(x: 0, y: size.height); drawing.scaleBy(x: 1, y: -1) }
                    drawing.clip(to: CGRect(origin: .zero, size: size))
                    drawing.textMatrix = .identity
                    drawing.textPosition = CGPoint(x: 0, y: size.height - shapedTitle.baseline)
                    CTLineDraw(line, drawing)
                    drawing.restoreGState()
                } else {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: drawing, flipped: flipped)
                    text.draw(in: CGRect(origin: .zero, size: size))
                    NSGraphicsContext.restoreGraphicsState()
                }
                rendering = Rendering(layer: layer, size: size, scale: scale, flipped: flipped, shapedLine: shapedLine)
                if fits { complete = rendering } else { rendered = rendering }
            }
            if let rendering {
                context.saveGState()
                if fits || shapedLine != nil { context.clip(to: rect) }
                if flipped {
                    context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
                    context.draw(rendering.layer, in: CGRect(origin: .zero, size: size))
                } else { context.draw(rendering.layer, in: CGRect(origin: rect.origin, size: size)) }
                context.restoreGState()
            }
        }
    }
    private static let font = NSFont.systemFont(ofSize: GridSelectionItem.headerFontSize, weight: .semibold)
    private static func attributes(centered: Bool? = nil, color: NSColor = .white) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        if let centered { paragraph.alignment = centered ? .center : .left }
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph.copy() as! NSParagraphStyle]
    }
    private static let titleAttributes = attributes()
    private static let gainAttributes = attributes(centered: false)
    private static let centeredAttributes = attributes(centered: true)
    private static let activeAttributes = attributes(centered: true, color: .systemGreen)
    private static let titles: NSCache<NSString, Title> = {
        let cache = NSCache<NSString, Title>()
        cache.countLimit = 256; cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()
    private static let gains: NSCache<NSString, Title> = {
        let cache = NSCache<NSString, Title>()
        cache.countLimit = 256; cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()
    static let mute = Title(NSAttributedString(string: "M", attributes: centeredAttributes))
    static let fx = Title(NSAttributedString(string: "FX", attributes: centeredAttributes))
    static let activeFX = Title(NSAttributedString(string: "FX", attributes: activeAttributes))
    static let edit = Title(NSAttributedString(string: "Edit", attributes: centeredAttributes))
    static func title(_ name: String) -> Title {
        if let cached = titles.object(forKey: name as NSString) { return cached }
        let value = Title(NSAttributedString(string: name, attributes: titleAttributes), prepareTitle: true)
        titles.setObject(value, forKey: name as NSString, cost: Int((ceil(value.width) + 4) * GridSelectionItem.headerHeight * 32) + name.utf8.count * 8 + 128)
        return value
    }
    static func gain(_ text: String) -> Title {
        if let cached = gains.object(forKey: text as NSString) { return cached }
        let value = Title(NSAttributedString(string: text, attributes: gainAttributes))
        gains.setObject(value, forKey: text as NSString, cost: Int((ceil(value.width) + 4) * GridSelectionItem.headerHeight * 32) + 128)
        return value
    }
}

/// Two fixed vector paths shared by main-thread header painting. Only their
/// origins change; needles retain the exact continuous gain/pan values.
private enum GridSelectionHeaderControls {
    static let backgroundColor = NSColor.black.withAlphaComponent(0.28)
    private static let green = NSColor(calibratedRed: 0.2, green: 1, blue: 0.55, alpha: 1)
    private static let ring: NSBezierPath = {
        let radius = 4.5 * GridSelectionItem.headerScale
        let p = NSBezierPath(ovalIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
        p.lineWidth = 1.5
        return p
    }()
    private static let phase: NSBezierPath = {
        let radius = 3.5 * GridSelectionItem.headerScale
        let p = NSBezierPath(ovalIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
        let diagonal = 4.5 * GridSelectionItem.headerScale
        p.move(to: CGPoint(x: -diagonal, y: diagonal))
        p.line(to: CGPoint(x: diagonal, y: -diagonal))
        p.lineWidth = 1.2
        return p
    }()
    static func knob(in rect: CGRect, position: Double, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        NSColor.black.setFill(); ring.fill()
        NSColor.white.setStroke(); ring.stroke()
        let angle = (135 + position * 270) * .pi / 180
        let radius = 3.5 * GridSelectionItem.headerScale
        context.beginPath()
        context.move(to: .zero)
        context.addLine(to: CGPoint(x: cos(angle) * radius, y: sin(angle) * radius))
        green.setStroke(); context.setLineWidth(2); context.setLineCap(.butt)
        context.setLineJoin(.miter); context.setMiterLimit(10); context.strokePath()
        context.restoreGState()
    }
    static func phase(in rect: CGRect, inverted: Bool, context: CGContext) {
        (inverted ? NSColor.systemYellow : backgroundColor).setFill(); rect.fill()
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        (inverted ? NSColor.black : NSColor.white).setStroke(); phase.stroke()
        context.restoreGState()
    }
}

/// Editing callbacks read the scale committed to the native input view, which
/// can lag a freshly requested zoom until the next layout transaction.
final class GridSelectionProjection {
    fileprivate(set) var pixelsPerSecond: CGFloat = 1
}
struct GridSelectionInput: NSViewRepresentable {
    let origin: CGPoint
    let headerHeight: CGFloat
    let items: [GridSelectionItem]
    let selected: Set<UUID>
    let selectionChanged: (Set<UUID>) -> Void
    let mute: (UUID) -> Void
    let move: (UUID, CGSize, CGFloat, Bool) -> Void
    let seek: (CGFloat, Bool) -> Void
    let createRegion: (UUID) -> Void
    var indexedLayout: GridSelectionLayout? = nil
    var pixelsPerSecond: CGFloat = 1
    var projection: GridSelectionProjection? = nil
    var interactionBlocked = false
    var resize: (UUID, Bool, CGFloat, Bool) -> Void = { _,_,_,_ in }
    var fade: (UUID, Bool, Double, Bool) -> Void = { _, _, _, _ in }
    var gain: (UUID, Double, Bool) -> Void = { _,_,_ in }
    var phase: (UUID) -> Void = { _ in }
    var pan: (UUID, Double, Bool) -> Void = { _,_,_ in }
    var fx: (UUID, Bool) -> Void = { _, _ in }
    var editMIDI: (UUID) -> Void = { _ in }
    var createMIDI: ((CGPoint, CGFloat?) -> Void)? = nil
    var editText: (UUID) -> Void = { _ in }
    var reRender: (Set<UUID>) -> Void = { _ in }
    var convert: (Set<UUID>, Int) -> Void = { _, _ in }
    var freezeMIDI: (Set<UUID>, Int) -> Void = { _, _ in }
    var glue: (Set<UUID>) -> Void = { _ in }
    var tuner: (Set<UUID>) -> Void = { _ in }
    var normalize: (Set<UUID>) -> Void = { _ in }
    var split: (Set<UUID>) -> Void = { _ in }
    var export: (Set<UUID>) -> Void = { _ in }
    var itemGuide: CGRect? = nil
    func projected(pixelsPerSecond: CGFloat, itemGuide: CGRect?) -> Self {
        var input = self
        input.pixelsPerSecond = pixelsPerSecond
        input.itemGuide = itemGuide
        return input
    }
    func makeNSView(context: Context) -> GridSelectionView { GridSelectionView() }
    func updateNSView(_ view: GridSelectionView, context: Context) { apply(to: view) }
    /// Reproject cached native targets without rebuilding editing callbacks.
    func applyProjection(to view: GridSelectionView, pixelsPerSecond: CGFloat, itemGuide: CGRect?) {
        projection?.pixelsPerSecond = pixelsPerSecond
        if let indexedLayout { view.updateLayout(indexedLayout, pixelsPerSecond: pixelsPerSecond) }
        view.itemGuide = itemGuide
    }
    func apply(to view: GridSelectionView) {
        projection?.pixelsPerSecond = pixelsPerSecond
        view.timelineOrigin = origin; view.headerHeight = headerHeight
        view.itemGuide = itemGuide
        view.interactionBlocked = interactionBlocked
        if let indexedLayout { view.updateLayout(indexedLayout, pixelsPerSecond: pixelsPerSecond) }
        else { view.items = items }
        view.updateSelection(selected)
        view.mute = mute; view.move = move; view.seek = seek; view.selectionChanged = selectionChanged; view.createRegion = createRegion; view.reRender = reRender; view.normalize = normalize; view.convert = convert; view.freezeMIDI = freezeMIDI; view.glue = glue; view.tuner = tuner; view.split = split; view.export = export; view.resize = resize; view.fade = fade; view.gain = gain; view.phase = phase; view.pan = pan; view.fx = fx; view.editText = editText; view.editMIDI = editMIDI; view.createMIDI = createMIDI
        view.observeHeaderScroll()
    }
}
final class GridSelectionView: NSView, NativeTimelineInputObserver, NativeTimelineBodyInput {
    var editMIDI: ((UUID) -> Void)?
    var createMIDI: ((CGPoint, CGFloat?) -> Void)?
    private var midiStart: CGPoint?
    private var midiContextPoint: CGPoint?
    var timelineOrigin = CGPoint.zero
    var headerHeight: CGFloat = 0 { didSet {
        if headerHeight != oldValue { updateCursorCoverage() }
    } }
    var interactionBlocked = false { didSet { if interactionBlocked && !oldValue { timelineInputGateChanged(blocked: true) } } }
    var items: [GridSelectionItem] = [] { didSet {
        updateLayout(GridSelectionLayout(items: items), pixelsPerSecond: 1)
    } }
    private var itemLayout = GridSelectionLayout(items: [])
    private var pixelsPerSecond: CGFloat = 1
    func updateLayout(_ layout: GridSelectionLayout, pixelsPerSecond: CGFloat) {
        guard itemLayout !== layout || self.pixelsPerSecond != pixelsPerSecond else { return }
        let changedLayout = itemLayout !== layout
        itemLayout = layout; self.pixelsPerSecond = pixelsPerSecond
        preparedHeaderProjection = nil
        invalidateHeaderProjectionIfNeeded()
        // Zoom moves item targets, but the registered body cursor rectangle
        // keeps the same viewport coverage. Refresh the item under the pointer
        // without making AppKit rebuild cursor rectangles every display frame.
        if changedLayout { window?.invalidateCursorRects(for: self) }
        refreshPointerCursor()
    }
    private func candidates(in rect: CGRect) -> [GridSelectionItem] {
        itemLayout.candidates(in: rect, pixelsPerSecond: pixelsPerSecond).map {
            itemLayout.projectedItem(at: $0, pixelsPerSecond: pixelsPerSecond)
        }
    }
    private func item(id: UUID) -> GridSelectionItem? {
        itemLayout.item(id: id, pixelsPerSecond: pixelsPerSecond)
    }
    private var headerScrolls: [NSClipView] = []
    private var headerScrollObservers: [NSObjectProtocol] = []
    /// Scrolling a long item moves its audio, but its left-pinned controls can
    /// stay pixel-identical for thousands of frames. Keep the view backing in
    /// that case; only visible fades/edges and changed controls require paint.
    private struct HeaderProjection: Equatable {
        let viewport: CGRect
        let headers: [HeaderPixels]
    }
    private struct HeaderPixels: Equatable {
        let id: UUID
        let rect: CGRect
        let name: String
        let gain: Double
        let pan: Double
        let phase: Bool
        let muted: Bool
        let hasFX: Bool
        let bypass: Bool
        let editable: Bool
        let midi: Bool
        let text: Bool
        let fadeRects: [CGRect?]
    }
    private var drawnHeaderProjection: HeaderProjection?
    private struct HeaderProjectionKey: Equatable {
        let viewport: CGRect
        let origin: CGPoint
        let height: CGFloat
        let gainID: UUID?
        let gain: Double?
        let panID: UUID?
        let pan: Double?
        let fadeID: UUID?
        let fadeLeft: Bool?
        let fadeSeconds: Double?
    }
    private struct PreparedHeaderProjection {
        let key: HeaderProjectionKey
        let pixels: HeaderProjection
        let drawings: [HeaderDrawing]
    }
    private struct HeaderDrawing {
        let item: GridSelectionItem
        let gainLabel: String?
    }
    private var preparedHeaderProjection: PreparedHeaderProjection?
    private var liveHeaderGain: (id: UUID, value: Double)?
    var itemGuide: CGRect? { didSet { if itemGuide != oldValue && heldItemGuide != nil { needsDisplay = true } } }
    private(set) var heldItemGuide: CGRect? { didSet { if heldItemGuide != oldValue { needsDisplay = true } } }
    var selected = Set<UUID>()
    var selectionChanged: ((Set<UUID>) -> Void)?
    var createRegion: ((UUID) -> Void)?
    var resize: ((UUID, Bool, CGFloat, Bool) -> Void)?
    var fade: ((UUID, Bool, Double, Bool) -> Void)?
    private var fadeItem: (item: GridSelectionItem, left: Bool)?
    private var liveFade: (id: UUID, left: Bool, seconds: Double)?
    var gain: ((UUID, Double, Bool) -> Void)?
    var phase: ((UUID) -> Void)?
    var pan: ((UUID, Double, Bool) -> Void)?
    var fx: ((UUID, Bool) -> Void)?
    var editText: ((UUID) -> Void)?
    private enum HeaderControl { case mute, fx, editText, phase }
    private var pressedHeader: (id: UUID, rect: CGRect, control: HeaderControl)?
    private var headerPressCancelled = false
    private var resizingLeft: Bool?
    private var gainItem: GridSelectionItem?
    private var panItem: GridSelectionItem?
    private var liveHeaderPan: (id: UUID, value: Double)?
    var reRender: ((Set<UUID>) -> Void)?
    var convert: ((Set<UUID>, Int) -> Void)?
    var freezeMIDI: ((Set<UUID>, Int) -> Void)?
    var glue: ((Set<UUID>) -> Void)?
    var tuner: ((Set<UUID>) -> Void)?
    var normalize: ((Set<UUID>) -> Void)?
    var split: ((Set<UUID>) -> Void)?
    var export: ((Set<UUID>) -> Void)?
    var mute: ((UUID) -> Void)?
    var move: ((UUID, CGSize, CGFloat, Bool) -> Void)?
    private var draggedItem: UUID?
    private var dragStart = CGPoint.zero
    private var dragOrigin = CGPoint.zero
    private var pendingSeek: CGPoint?
    private var hasDragged = false
    private var movingAllowed = false
    var seek: ((CGFloat, Bool) -> Void)?
    private var anchor: CGPoint?
    private var selectionRect: CGRect?
    private var baseSelection = Set<UUID>()
    private var additive = false
    private var contextItem: UUID?
    private var pointerMonitor: Any?
    private var activeButton: Int?
    private var anchorInWindow = CGPoint.zero
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !interactionBlocked, !NativeTimelineInputGate.shared.isBlocked(window), window?.attachedSheet == nil,
              !isHiddenOrHasHiddenAncestor else { return nil }
        let local = convert(point, from: superview), viewport = coordinates.viewport
        guard bounds.contains(local), visibleRect.contains(local), viewport.contains(local),
              local.y >= viewport.minY + headerHeight else { return nil }
        // Returning nil allowed the hosting view underneath to reset edge/fade
        // cursors after our handler. Ruler and floating editors stay separate.
        return self
    }
    func hitTestTimelineBody(atWindowPoint point: NSPoint) -> NSView? {
        let local = convert(point, from: nil)
        // Needle heads extend six points below the ruler and take precedence.
        guard local.y > coordinates.viewport.minY + headerHeight + 6 else { return nil }
        return hitTest(convert(local, to: superview))
    }
    func updateSelection(_ next: Set<UUID>) {
        if anchor == nil { selected = next }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        cursorCoverage = nil
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor); self.pointerMonitor = nil }
        heldItemGuide = nil
        pendingSeek = nil
        midiStart = nil; activeButton = nil; anchor = nil; selectionRect = nil; draggedItem = nil; hasDragged = false
        pressedHeader = nil; headerPressCancelled = false
        guard window != nil else { return }
        window?.acceptsMouseMovedEvents = true
        observeHeaderScroll()
        NativeTimelineInputGate.shared.add(self)
        pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseDragged, .rightMouseUp]) { [weak self] event in
            self?.handlePointerEvent(event) == true ? nil : event
        }
    }
    deinit {
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        for observer in headerScrollObservers { NotificationCenter.default.removeObserver(observer) }
    }
    func observeHeaderScroll() {
        var clips: [NSClipView] = [], parent = superview
        while let view = parent {
            if let timeline = view as? NativeTimelineBodyInputHost { timeline.timelineBodyInput = self }
            if let scroll = view as? NSScrollView { clips.append(scroll.contentView) }
            parent = view.superview
        }
        guard clips.map(ObjectIdentifier.init) != headerScrolls.map(ObjectIdentifier.init) else { return }
        for observer in headerScrollObservers { NotificationCenter.default.removeObserver(observer) }
        headerScrolls = clips
        headerScrollObservers = clips.map { clip in
            clip.postsBoundsChangedNotifications = true
            return NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                self?.invalidateHeaderProjectionIfNeeded()
                // The input host stays pinned in the viewport. Its one body
                // cursor rectangle does not move when timeline content moves;
                // refreshPointerCursor resolves the new item under the mouse.
                self?.refreshPointerCursor()
            }
        }
    }
    private func positionedHeader(_ source: GridSelectionItem) -> GridSelectionItem {
        let space = coordinates
        return positionedHeader(source, viewport: space.viewport, origin: space.origin)
    }
    private func positionedHeader(_ source: GridSelectionItem, viewport: CGRect, origin: CGPoint, gainLabel: String? = nil) -> GridSelectionItem {
        guard let name = source.name else { return source }
        var item = source
        if liveHeaderGain?.id == item.id { item.gain = liveHeaderGain!.value }
        if let liveFade, liveFade.id == item.id {
            if liveFade.left { item.fadeIn = liveFade.seconds } else { item.fadeOut = liveFade.seconds }
        }
        return item.visibleLeftHeader(in: CGRect(origin: origin, size: viewport.size), titleWidth: GridSelectionHeaderText.title(name).width, gainLabel: gainLabel)
    }
    // Use native scroll bounds, not the delayed SwiftUI offset from its last render.
    private var coordinates: (viewport: CGRect, origin: CGPoint) {
        var scrolls: [NSScrollView] = []
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? NSScrollView { scrolls.append(scroll) }
            ancestor = view.superview
        }
        guard let horizontal = scrolls.first, let vertical = scrolls.last, horizontal !== vertical else { return (bounds, timelineOrigin) }
        let viewport = convert(horizontal.contentView.bounds, from: horizontal.contentView)
            .intersection(convert(vertical.contentView.bounds, from: vertical.contentView))
        return (viewport, CGPoint(x: horizontal.contentView.bounds.minX, y: vertical.contentView.bounds.minY))
    }
    private func headerProjection(viewport: CGRect, origin: CGPoint) -> HeaderProjection {
        prepareHeaderProjection(viewport: viewport, origin: origin).pixels
    }
    /// The invalidation comparison and drawing consume the same projection.
    /// Cache only one exact coordinate/state snapshot; never reuse it across a
    /// changed layout, scale, viewport, or an in-progress control edit.
    private func prepareHeaderProjection(viewport: CGRect, origin: CGPoint) -> PreparedHeaderProjection {
        let key = HeaderProjectionKey(viewport: viewport, origin: origin, height: headerHeight,
            gainID: liveHeaderGain?.id, gain: liveHeaderGain?.value,
            panID: liveHeaderPan?.id, pan: liveHeaderPan?.value,
            fadeID: liveFade?.id, fadeLeft: liveFade?.left, fadeSeconds: liveFade?.seconds)
        if let preparedHeaderProjection, preparedHeaderProjection.key == key { return preparedHeaderProjection }
        let body = CGRect(x: viewport.minX, y: viewport.minY + headerHeight,
                          width: viewport.width, height: max(0, viewport.height - headerHeight))
        #if CATLIVE_RENDER_DIAGNOSTICS
        if TimelineRenderDiagnosticBypass.contains("item-headers") {
            let prepared = PreparedHeaderProjection(key: key,
                pixels: HeaderProjection(viewport: body, headers: []), drawings: [])
            preparedHeaderProjection = prepared
            return prepared
        }
        #endif
        let visible = body.offsetBy(dx: origin.x - viewport.minX, dy: origin.y - viewport.minY)
        var drawings: [HeaderDrawing] = []
        let headers = candidates(in: visible).compactMap { source -> HeaderPixels? in
            guard source.name != nil, source.rect.width >= 20,
                  source.rect.maxX >= visible.minX, source.rect.minX <= visible.maxX else { return nil }
            var source = source
            if liveHeaderGain?.id == source.id { source.gain = liveHeaderGain!.value }
            let visibleWidth = max(0, min(source.rect.maxX, origin.x + viewport.width) - max(source.rect.minX, origin.x))
            let gainLabel = source.editable && visibleWidth >= (source.midiEditable ? 57 : 134) * GridSelectionItem.headerScale ? source.gainLabel : nil
            var item = positionedHeader(source, viewport: viewport, origin: origin, gainLabel: gainLabel)
            let dx = viewport.minX - origin.x, dy = viewport.minY - origin.y
            item.rect = item.rect.offsetBy(dx: dx, dy: dy)
            item.visibleHeader = item.visibleHeader?.offsetBy(dx: dx, dy: dy)
            if liveHeaderPan?.id == item.id { item.pan = liveHeaderPan!.value }
            let fadeRects = item.fadeDrawingRects(in: body)
            drawings.append(HeaderDrawing(item: item, gainLabel: gainLabel))
            return HeaderPixels(id: item.id, rect: item.headerRect, name: item.name!, gain: item.gain, pan: item.pan,
                phase: item.phaseInverted, muted: item.muted, hasFX: item.hasFX, bypass: item.fxBypassed,
                editable: item.editable, midi: item.midiEditable, text: item.textEditable, fadeRects: fadeRects)
        }
        let prepared = PreparedHeaderProjection(key: key,
            pixels: HeaderProjection(viewport: body, headers: headers), drawings: drawings)
        preparedHeaderProjection = prepared
        return prepared
    }
    @discardableResult private func invalidateHeaderProjectionIfNeeded() -> Bool {
        guard !needsDisplay else { return false }
        let space = coordinates
        if selectionRect != nil || heldItemGuide != nil ||
            drawnHeaderProjection != headerProjection(viewport: space.viewport, origin: space.origin) {
            needsDisplay = true
            return true
        }
        return false
    }
    private func timelinePoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let space = coordinates
        return CGPoint(x: point.x - space.viewport.minX + space.origin.x, y: point.y - space.viewport.minY + space.origin.y)
    }
    private func hitItem(at point: CGPoint) -> GridSelectionItem? {
        let rowItems = candidates(in: CGRect(x: point.x - 10, y: point.y, width: 20, height: 0))
        if let inside = rowItems.first(where: { $0.rect.contains(point) }) { return positionedHeader(inside) }
        return rowItems.filter { $0.resizeSide(at: point) != nil }.min {
            min(abs(point.x - $0.rect.minX), abs(point.x - $0.rect.maxX)) <
            min(abs(point.x - $1.rect.minX), abs(point.x - $1.rect.maxX))
        }.map(positionedHeader)
    }
    @discardableResult func handlePointerEvent(_ event: NSEvent) -> Bool {
        guard !interactionBlocked, !NativeTimelineInputGate.shared.isBlocked(window), event.window === window, window != nil, window?.attachedSheet == nil,
              !isHiddenOrHasHiddenAncestor else { return false }
        let down = event.type == .leftMouseDown || event.type == .rightMouseDown
        if down {
            let point = convert(event.locationInWindow, from: nil)
            let viewport = coordinates.viewport
            // Hosting can keep an obsolete input view attached during layout.
            // Its monitor must never intercept a click outside its visible area.
            guard bounds.contains(point), visibleRect.contains(point),
                  viewport.contains(point), point.y >= viewport.minY + headerHeight else { return false }
            activeButton = event.buttonNumber
        } else if activeButton != event.buttonNumber { return false }
        switch event.type {
        case .leftMouseDown: mouseDown(with: event)
        case .leftMouseDragged: mouseDragged(with: event)
        case .leftMouseUp: activeButton = nil; mouseUp(with: event)
        case .rightMouseDown: rightMouseDown(with: event)
        case .rightMouseDragged: rightMouseDragged(with: event)
        case .rightMouseUp: activeButton = nil; rightMouseUp(with: event)
        default: return false
        }
        return true
    }
    func timelineInputGateChanged(blocked: Bool) {
        guard blocked else { return }
        if let fadeItem { fade?(fadeItem.item.id, fadeItem.left, fadeItem.left ? fadeItem.item.fadeIn : fadeItem.item.fadeOut, false) }
        fadeItem = nil; liveFade = nil
        heldItemGuide = nil
        pendingSeek = nil
        // A modal opened during a press must not leave a latent mouse-up action.
        activeButton = nil; anchor = nil; selectionRect = nil; contextItem = nil
        draggedItem = nil; hasDragged = false; movingAllowed = false
        pressedHeader = nil; headerPressCancelled = false; gainItem = nil; panItem = nil; liveHeaderPan = nil; resizingLeft = nil
        needsDisplay = true
    }
    func timelinePendingClickCancelled() {
        guard activeButton == 0, !hasDragged else { return }
        heldItemGuide = nil
        pendingSeek = nil
        // Keep ownership of mouse-up so it cannot activate another view after
        // the viewport has moved. Existing item/gain/edge drags still commit.
        draggedItem = nil; movingAllowed = false; resizingLeft = nil; gainItem = nil; panItem = nil; liveHeaderPan = nil; fadeItem = nil; liveFade = nil
        pressedHeader = nil; headerPressCancelled = false
    }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        heldItemGuide = nil
        pendingSeek = nil
        dragStart = event.locationInWindow
        let timeline = timelinePoint(event)
        draggedItem = nil; hasDragged = false; movingAllowed = false; resizingLeft = nil; gainItem = nil; panItem = nil; liveHeaderPan = nil; fadeItem = nil; liveFade = nil
        pressedHeader = nil; headerPressCancelled = false
        guard let item = hitItem(at: timeline) else {
            if createMIDI != nil && event.clickCount == 2 { createMIDI?(timeline, nil); return }
            if createMIDI != nil && !event.modifierFlags.intersection([.command,.control]).isEmpty { midiStart = timeline; return }
            pendingSeek = timeline; return
        }
        if item.midiEditable && event.clickCount == 2 { editMIDI?(item.id); return }
        if let left = item.fadeSide(at: timeline) {
            fadeItem = (item, left); draggedItem = item.id; dragStart = event.locationInWindow
            return
        }
        if let rect = item.editRect, rect.contains(timeline) {
            pressedHeader = (item.id, rect, .editText); dragStart = event.locationInWindow; return
        } else if let rect = item.phaseRect, rect.contains(timeline) {
            pressedHeader = (item.id, rect, .phase); dragStart = event.locationInWindow; return
        } else if item.panKnobRect?.contains(timeline) == true {
            if event.clickCount == 2 { pan?(item.id, 0, true); return }
            panItem = item; draggedItem = item.id; dragStart = event.locationInWindow; return
        } else if item.gainKnobRect?.contains(timeline) == true {
            if event.clickCount == 2 { gain?(item.id, 1, true); return }
            gainItem = item; draggedItem = item.id; dragStart = event.locationInWindow; return
        } else if let rect = item.fxRect, rect.contains(timeline) {
            pressedHeader = (item.id, rect, .fx); dragStart = event.locationInWindow; return
        } else if let rect = item.muteRect, rect.contains(timeline) {
            pressedHeader = (item.id, rect, .mute); dragStart = event.locationInWindow; return
        } else { resizingLeft = item.resizeSide(at: timeline) }
        heldItemGuide = item.rect
        pendingSeek = timeline
        let additive = !event.modifierFlags.intersection([.command, .control]).isEmpty
        if additive {
            if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
        } else { selected = [item.id] }
        selectionChanged?(selected)
        movingAllowed = item.movable
        draggedItem = item.id; dragStart = event.locationInWindow; dragOrigin = timeline
    }
    override func mouseDragged(with event: NSEvent) {
        if let start = midiStart {
            let point = timelinePoint(event)
            selectionRect = CGRect(x: min(start.x, point.x), y: start.y - 10, width: max(1, abs(point.x - start.x)), height: 20)
            needsDisplay = true; return
        }
        if hypot(event.locationInWindow.x - dragStart.x, event.locationInWindow.y - dragStart.y) >= 3 { pendingSeek = nil }
        if pressedHeader != nil {
            if hypot(event.locationInWindow.x - dragStart.x, event.locationInWindow.y - dragStart.y) >= 3 {
                headerPressCancelled = true
            }
            return
        }
        guard let id = draggedItem else { return }
        let translation = CGSize(width: event.locationInWindow.x - dragStart.x, height: dragStart.y - event.locationInWindow.y)
        guard hasDragged || hypot(translation.width, translation.height) >= 3 else { return }
        hasDragged = true
        if let fadeItem {
            let seconds = fadeItem.item.draggingFade(left: fadeItem.left, delta: translation.width)
            liveFade = (id, fadeItem.left, seconds); needsDisplay = true
            fade?(id, fadeItem.left, seconds, false)
        }
        else if let resizingLeft { resize?(id, resizingLeft, translation.width, false) }
        else if let panItem {
            let value = panItem.draggingPan(by: translation.height)
            liveHeaderPan = (id, value); needsDisplay = true
            pan?(id, value, false)
        }
        else if let gainItem {
            let value = gainItem.draggingGain(by: translation.height)
            liveHeaderGain = (id, value); needsDisplay = true
            gain?(id, value, false)
        }
        else if movingAllowed { move?(id, translation, dragOrigin.y + translation.height, false) }
    }
    override func mouseUp(with event: NSEvent) {
        if let start = midiStart {
            let end = timelinePoint(event).x
            midiStart = nil; selectionRect = nil; needsDisplay = true
            if abs(end - start.x) >= 3 { createMIDI?(CGPoint(x:min(start.x,end),y:start.y),abs(end-start.x)) }
            return
        }
        heldItemGuide = nil
        let click = pendingSeek
        pendingSeek = nil
        if let header = pressedHeader {
            pressedHeader = nil
            let stillAvailable = item(id: header.id).map { header.control == .editText ? $0.textEditable : $0.editable } ?? false
            let activate = !headerPressCancelled && header.rect.contains(timelinePoint(event)) && stillAvailable
            headerPressCancelled = false
            // The native monitor consumes this mouse-up. A sheet opened here
            // cannot receive the release that activated its originating FX button.
            if activate {
                switch header.control {
                case .phase: phase?(header.id)
                case .mute: mute?(header.id)
                case .fx: fx?(header.id, event.modifierFlags.contains(.option))
                case .editText: editText?(header.id)
                }
            }
            return
        }
        if let click, !hasDragged,
           hypot(event.locationInWindow.x - dragStart.x, event.locationInWindow.y - dragStart.y) < 3,
           !interactionBlocked, !NativeTimelineInputGate.shared.isBlocked(window), window?.attachedSheet == nil {
            let released = convert(event.locationInWindow, from: nil), viewport = coordinates.viewport
            if bounds.contains(released), visibleRect.contains(released), viewport.contains(released), released.y >= viewport.minY + headerHeight {
                seek?(click.x, event.modifierFlags.contains(.shift))
            }
        }
        if let id = draggedItem, hasDragged {
            let translation = CGSize(width: event.locationInWindow.x - dragStart.x, height: dragStart.y - event.locationInWindow.y)
            if let fadeItem { fade?(id, fadeItem.left, fadeItem.item.draggingFade(left: fadeItem.left, delta: translation.width), true) }
            else if let resizingLeft { resize?(id, resizingLeft, translation.width, true) }
            else if let panItem { pan?(id, panItem.draggingPan(by: translation.height), true) }
            else if let gainItem { gain?(id, gainItem.draggingGain(by: translation.height), true) }
            else if movingAllowed {
                let point = convert(event.locationInWindow, from: nil)
                let inside = coordinates.viewport.contains(point)
                move?(id, translation, inside ? dragOrigin.y + translation.height : .nan, true)
            }
        }
        draggedItem = nil; hasDragged = false; movingAllowed = false; gainItem = nil; panItem = nil; liveHeaderPan = nil; liveHeaderGain = nil; fadeItem = nil; liveFade = nil; needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateCursorCoverage()
        // inVisibleRect follows clipping and geometry changes in AppKit.
        // Replacing it on every follow-scroll invalidates cursor tracking
        // throughout the window without changing this area's coverage.
        guard trackingAreas.isEmpty else { return }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }
    private var cursorCoverage: CGRect?
    private var bodyCursorRect: CGRect {
        let space = coordinates
        let body = space.viewport.intersection(bounds).intersection(visibleRect)
        let top = max(body.minY, space.viewport.minY + headerHeight)
        return CGRect(x: body.minX, y: top, width: body.width, height: max(0, body.maxY - top))
    }
    private func updateCursorCoverage() {
        let content = bodyCursorRect
        guard cursorCoverage != content else { return }
        cursorCoverage = content
        window?.invalidateCursorRects(for: self)
    }
    override func resetCursorRects() {
        guard !interactionBlocked, !NativeTimelineInputGate.shared.isBlocked(window), window?.attachedSheet == nil else { return }
        let content = bodyCursorRect
        cursorCoverage = content
        guard content.width > 0, content.height > 0 else { return }
        addCursorRect(content, cursor: .arrow)
        // The automatic tracking area owns item-specific cursors through
        // cursorUpdate/mouseMoved. Registering every item edge, knob and button
        // again on each playback scroll duplicated that hit-testing work.
    }
    func pointerCursor(at point: CGPoint) -> NSCursor {
        guard let item = hitItem(at: point) else { return .arrow }
        if item.fadeSide(at: point) != nil { return .crosshair }
        if item.panKnobRect?.contains(point) == true { return .resizeUpDown }
        if item.gainKnobRect?.contains(point) == true { return .resizeUpDown }
        if item.fxRect?.contains(point) == true || item.muteRect?.contains(point) == true || item.editRect?.contains(point) == true { return .pointingHand }
        return item.resizeSide(at: point) != nil ? .resizeLeftRight : .arrow
    }
    private func refreshPointerCursor(_ event: NSEvent? = nil) {
        guard let window, window.attachedSheet == nil,
              !interactionBlocked, !NativeTimelineInputGate.shared.isBlocked(window),
              !isHiddenOrHasHiddenAncestor, activeButton == nil else { return }
        let point = convert(event?.locationInWindow ?? window.mouseLocationOutsideOfEventStream, from: nil)
        let space = coordinates
        guard bounds.contains(point), visibleRect.contains(point), space.viewport.contains(point),
              point.y >= space.viewport.minY + headerHeight else { return }
        let desired = pointerCursor(at: CGPoint(x: point.x - space.viewport.minX + space.origin.x,
                                               y: point.y - space.viewport.minY + space.origin.y))
        // Consult AppKit's actual cursor: another control or app activation can
        // replace it while the pointer stays over the same timeline target.
        if NSCursor.current !== desired { desired.set() }
    }
    override func mouseMoved(with event: NSEvent) { refreshPointerCursor(event) }
    override func mouseEntered(with event: NSEvent) { refreshPointerCursor(event) }
    override func cursorUpdate(with event: NSEvent) { refreshPointerCursor(event) }
    override func mouseExited(with event: NSEvent) {
        if NSCursor.current !== NSCursor.arrow { NSCursor.arrow.set() }
    }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        anchor = timelinePoint(event)
        anchorInWindow = event.locationInWindow
        additive = !event.modifierFlags.intersection([.shift, .command, .control]).isEmpty
        baseSelection = additive ? selected : []
        selectionRect = nil
    }
    override func rightMouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let point = timelinePoint(event)
        guard selectionRect != nil || hypot(event.locationInWindow.x-anchorInWindow.x, event.locationInWindow.y-anchorInWindow.y) >= 3 else { return }
        let top = max(coordinates.origin.y + headerHeight, min(anchor.y, point.y))
        let rect = CGRect(x: min(anchor.x,point.x), y: top, width: max(1,abs(point.x-anchor.x)), height: max(1,max(anchor.y,point.y)-top))
        selectionRect = rect
        let next = baseSelection.union(candidates(in: rect).lazy.filter { $0.rect.intersects(rect) }.map(\.id))
        if selected != next { selected = next; selectionChanged?(next) }
        needsDisplay = true
    }
    override func rightMouseUp(with event: NSEvent) {
        guard let anchor else { return }
        rightMouseDragged(with: event)
        if selectionRect == nil {
            contextItem = candidates(in: CGRect(origin: anchor, size: .zero)).first { $0.rect.contains(anchor) }?.id
            if let contextItem {
                if !selected.contains(contextItem) { selected = [contextItem]; selectionChanged?(selected) }
                guard item(id: contextItem)?.contextActions == true || selected.contains(where: { id in
                    guard let item = item(id: id) else { return false }
                    return item.editable && item.audioExportable
                }) else {
                    self.anchor = nil; selectionRect = nil; needsDisplay = true
                    return
                }
                let menu = itemContextMenu(for: contextItem)
                NSMenu.popUpContextMenu(menu, with: event, for: self)
            } else {
                if !additive { selected.removeAll(); selectionChanged?([]) }
                if createMIDI != nil {
                    midiContextPoint = anchor
                    let menu = NSMenu()
                    let entry = NSMenuItem(title: "Criar item MIDI", action: #selector(createContextMIDI), keyEquivalent: "")
                    entry.target = self; menu.addItem(entry); NSMenu.popUpContextMenu(menu, with: event, for: self)
                }
            }
        }
        self.anchor = nil; selectionRect = nil; needsDisplay = true
    }
    func itemContextMenu(for contextItem: UUID) -> NSMenu {
        self.contextItem = contextItem
        let menu = NSMenu()
        if item(id: contextItem)?.midiEditable == true {
            let muted = selectedMIDIItems.allSatisfy(\.muted)
            let toggle = NSMenuItem(title: JarasLocalization.string(muted ? "Unmute items" : "Mute items"), action: #selector(muteMIDISelection), keyEquivalent: "")
            toggle.target = self; menu.addItem(toggle)
            for (channels, title) in [(1, "Convert Mono"), (2, "Convert Stereo")] {
                let option = NSMenuItem(title: JarasLocalization.string(title), action: #selector(freezeMIDISelection(_:)), keyEquivalent: "")
                option.tag = channels; option.target = self; menu.addItem(option)
            }
            let glue = NSMenuItem(title: JarasLocalization.string("Unify items"), action: #selector(glueSelection), keyEquivalent: "")
            glue.target = self; menu.addItem(glue)
            return menu
        } else if item(id: contextItem)?.contextActions == true {
                let item = NSMenuItem(title: JarasLocalization.string("Criar região do item"), action: #selector(createContextRegion), keyEquivalent: "")
                item.target = self; menu.addItem(item)
                let freeze = NSMenuItem(title: JarasLocalization.string("Re-render"), action: #selector(reRenderSelection), keyEquivalent: "")
                freeze.target = self; menu.addItem(freeze)
                let glue = NSMenuItem(title: JarasLocalization.string("Unify items"), action: #selector(glueSelection), keyEquivalent: "")
                glue.target = self; menu.addItem(glue)
                let tuner = NSMenuItem(title: "Tuner", action: #selector(tuneSelection), keyEquivalent: "")
                tuner.target = self; menu.addItem(tuner)
                let normalize = NSMenuItem(title: JarasLocalization.string("Normalize…"), action: #selector(normalizeSelection), keyEquivalent: "")
                normalize.target = self; menu.addItem(normalize)
                let split = NSMenuItem(title: JarasLocalization.string("Split at edit cursor…"), action: #selector(splitSelection), keyEquivalent: "")
                split.target = self; menu.addItem(split)
                if self.item(id: contextItem)?.editable == true {
                    menu.addItem(.separator())
                    for (mode, title) in [(1,"Convert Mono - L"), (2,"Convert Mono - R"), (3,"Convert Mono L-R"), (0,"Convert Stereo")] {
                        let option = NSMenuItem(title: JarasLocalization.string(title), action: #selector(convertSelection(_:)), keyEquivalent: "")
                        option.tag = mode; option.target = self; menu.addItem(option)
                    }
                }
        }
        let audioItems = selected.compactMap { item(id: $0) }.filter(\.editable)
        if !audioItems.isEmpty {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let muted = audioItems.allSatisfy(\.muted)
            let toggle = NSMenuItem(title: JarasLocalization.string(muted ? "Unmute items" : "Mute items"), action: #selector(muteSelection), keyEquivalent: "")
            toggle.target = self; menu.addItem(toggle)
        }
        menu.addItem(.separator())
        let export = NSMenuItem(title: JarasLocalization.string("Export"), action: #selector(exportSelection), keyEquivalent: "")
        export.target = self
        export.isEnabled = selected.contains { item(id: $0).map { $0.editable && $0.audioExportable } == true }
        menu.addItem(export)
        menu.autoenablesItems = false
        return menu
    }
    @objc private func createContextMIDI() { if let point = midiContextPoint { createMIDI?(point, nil) } }
    @objc private func editContextMIDI() { if let contextItem { editMIDI?(contextItem) } }
    private var selectedMIDIItems: [GridSelectionItem] {
        selected.compactMap { item(id: $0) }.filter { $0.editable && $0.midiEditable }
    }
    @objc private func muteMIDISelection() {
        let items = selectedMIDIItems, muted = !selectedMIDIItems.allSatisfy(\.muted)
        for item in items where item.muted != muted { mute?(item.id) }
    }
    @objc private func freezeMIDISelection(_ sender: NSMenuItem) {
        let ids = Set(selectedMIDIItems.map(\.id))
        if !ids.isEmpty { freezeMIDI?(ids, sender.tag) }
    }
    @objc private func muteSelection() {
        let audioItems = selected.compactMap { item(id: $0) }.filter(\.editable)
        let muted = !audioItems.allSatisfy(\.muted)
        for item in audioItems where item.muted != muted { mute?(item.id) }
    }
    @objc private func exportSelection() {
        let audio = Set(selected.filter { item(id: $0).map { $0.editable && $0.audioExportable } == true })
        if !audio.isEmpty { export?(audio) }
    }
    @objc private func tuneSelection() {
        let ids = Set(selected.filter { item(id: $0).map { $0.audioExportable && !$0.midiEditable } == true })
        if !ids.isEmpty { tuner?(ids) }
    }
    @objc private func reRenderSelection() { reRender?(selected) }
    @objc private func glueSelection() {
        let ids = Set(selected.filter { item(id: $0).map { $0.editable && ($0.audioExportable || $0.midiEditable) } == true })
        if !ids.isEmpty { glue?(ids) }
    }
    @objc private func convertSelection(_ sender: NSMenuItem) { convert?(selected, sender.tag) }
    @objc private func normalizeSelection() { normalize?(selected) }
    @objc private func splitSelection() { split?(selected) }
    @objc private func createContextRegion() { if let contextItem { createRegion?(contextItem) } }
    override func draw(_ dirtyRect: NSRect) {
        let space = coordinates
        let headers = prepareHeaderProjection(viewport: space.viewport, origin: space.origin)
        drawHeaders(headers)
        drawnHeaderProjection = headers.pixels
        if let heldItemGuide {
            let guide = itemGuide ?? heldItemGuide
            let lines = NSBezierPath()
            for boundary in [guide.minX - 1, guide.maxX + 1] {
                let x = boundary + space.viewport.minX - space.origin.x
                lines.move(to: CGPoint(x: x, y: space.viewport.minY + headerHeight))
                lines.line(to: CGPoint(x: x, y: space.viewport.maxY))
            }
            NSColor.yellow.setStroke()
            lines.lineWidth = 1
            lines.stroke()
        }
        guard let timelineRect = selectionRect else { return }
        let rect = timelineRect.offsetBy(dx: space.viewport.minX - space.origin.x, dy: space.viewport.minY - space.origin.y)
        NSColor.systemGreen.withAlphaComponent(0.12).setFill()
        NSBezierPath(rect: rect).fill()
        NSColor.systemGreen.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)); border.lineWidth = 1; border.stroke()
    }
    private func drawItemFades(_ item: GridSelectionItem) {
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
    private func drawHeaders(_ projection: PreparedHeaderProjection) {
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext.current!.cgContext
        context.clip(to: projection.pixels.viewport)
        defer { NSGraphicsContext.restoreGraphicsState() }
        for drawing in projection.drawings {
                let item = drawing.item
                if let rect = item.muteRect {
                    (item.muted ? NSColor.systemRed : GridSelectionHeaderControls.backgroundColor).setFill(); rect.fill()
                    GridSelectionHeaderText.mute.draw(in: rect.insetBy(dx: 1, dy: 0))
                }
                if let rect = item.fxRect {
                    (item.fxBypassed ? NSColor.systemRed : GridSelectionHeaderControls.backgroundColor).setFill(); rect.fill()
                    (item.hasFX && !item.fxBypassed ? GridSelectionHeaderText.activeFX : GridSelectionHeaderText.fx)
                        .draw(in: rect.insetBy(dx: 1, dy: 0))
                }
                if let rect = item.editRect {
                    GridSelectionHeaderControls.backgroundColor.setFill(); rect.fill()
                    GridSelectionHeaderText.edit.draw(in: rect.insetBy(dx: 1, dy: 0))
                }
                if let rect = item.gainKnobRect {
                    GridSelectionHeaderControls.knob(in: rect, position: item.gainPosition, context: context)
                }
                if let rect = item.phaseRect {
                    GridSelectionHeaderControls.phase(in: rect, inverted: item.phaseInverted, context: context)
                }
                if let rect = item.panKnobRect {
                    GridSelectionHeaderControls.knob(in: rect, position: (item.pan + 1) / 2, context: context)
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
#endif

#if os(macOS)
extension GridSelectionView: TimelineGridKeyboardTarget {}
#endif
