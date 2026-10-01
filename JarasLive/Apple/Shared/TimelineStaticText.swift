import SwiftUI
import CoreText
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The ruler's small labels never scale with horizontal zoom. Shape and raster
/// them once at the window's backing scale, then move the same image with the
/// timeline. This avoids text layout and glyph drawing on every zoom frame.
final class TimelineStaticText: NSObject {
    enum Style: Int { case barNumber, regionIdentifier }
    private static let cache: NSCache<NSString, TimelineStaticText> = {
        let value = NSCache<NSString, TimelineStaticText>()
        value.countLimit = 4096
        value.totalCostLimit = 8 * 1024 * 1024
        return value
    }()
    let image: CGImage
    let size: CGSize
    let width: CGFloat
    private let scale: CGFloat

    private init?(text: String, style: Style, scale: CGFloat) {
        #if os(macOS)
        let font = NSFont.monospacedSystemFont(ofSize: 9, weight: style == .regionIdentifier ? .semibold : .medium)
        #else
        let font = UIFont.monospacedSystemFont(ofSize: 9, weight: style == .regionIdentifier ? .semibold : .medium)
        #endif
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 1)
        ]))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        width = ceil(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let size = CGSize(width: max(1, width + 2), height: max(1, ceil(ascent + descent + leading)))
        let pixelWidth = Int(ceil(size.width * scale)), pixelHeight = Int(ceil(size.height * scale))
        guard let bitmap = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        bitmap.scaleBy(x: scale, y: scale)
        bitmap.setShouldAntialias(true)
        bitmap.setShouldSmoothFonts(false)
        bitmap.textPosition = CGPoint(x: 1, y: size.height - ascent)
        CTLineDraw(line, bitmap)
        guard let image = bitmap.makeImage() else { return nil }
        self.image = image; self.size = size; self.scale = scale
    }

    static func label(_ text: String, style: Style, displayScale: CGFloat) -> TimelineStaticText? {
        let scale = displayScale.isFinite ? min(4, max(1, displayScale)) : 1
        let key = "\(style.rawValue)|\(scale)|\(text)" as NSString
        if let label = cache.object(forKey: key) { return label }
        guard let label = TimelineStaticText(text: text, style: style, scale: scale) else { return nil }
        cache.setObject(label, forKey: key, cost: label.image.bytesPerRow * label.image.height)
        return label
    }

    func draw(at point: CGPoint, trailing: Bool = false, context: inout GraphicsContext) {
        let origin = CGPoint(x: (trailing ? point.x - width : point.x) - 1, y: point.y)
        context.draw(Image(decorative: image, scale: scale), in: CGRect(origin: origin, size: size))
    }
}
