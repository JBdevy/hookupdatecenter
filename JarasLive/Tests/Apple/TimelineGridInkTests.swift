import SwiftUI
#if os(iOS)
import UIKit
#endif

@MainActor func verifyTimelineGridInk() {
    let ink = TimelineGridPathCache()
    let path = ink.path(positions: [1_000_000_040, 1_000_000_080], origin: 1_000_000_000,
                        top: 30, bottom: 180, inset: 0.25)
    for _ in 0..<600 {
        precondition(ink.path(positions: [1_000_000_040, 1_000_000_080], origin: 1_000_000_000,
                              top: 30, bottom: 180, inset: 0.25) === path)
    }
    precondition(ink.builds == 1, "Transport updates must reuse the same drawing")
    precondition(path.boundingBox == CGRect(x: 40.25, y: 30, width: 40, height: 150), "Large coordinates retain precision")
    let resized = ink.path(positions: [40, 80], origin: 0, top: 30, bottom: 260, inset: 0.25)
    precondition(resized !== path && resized.boundingBox.maxY == 260, "Track height updates must invalidate geometry")
    precondition(ink.path(positions: [], origin: 0, top: 0, bottom: 260).isEmpty, "Disabling the grid must remove old lines")

    #if os(iOS)
    let view = TimelineRetainedGridView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
    func update(_ positions: [CGFloat] = [40.25, 80.25], color: CGColor = CGColor(gray: 1, alpha: 1)) {
        view.update(primary: positions, secondary: [120.25], primaryColor: color,
                    secondaryColor: CGColor(gray: 0.5, alpha: 1), scale: 2)
        view.layoutIfNeeded()
    }
    update()
    let layers = view.layer.sublayers!.map { $0 as! CAShapeLayer }
    let primary = layers[0].path!, secondary = layers[1].path!
    for _ in 0..<600 { update() }
    precondition(layers[0].path === primary && layers[1].path === secondary, "iPad retains grid paths across playback frames")
    update(color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    precondition(layers[0].path === primary, "Appearance changes reuse geometry")
    precondition(layers[0].strokeColor!.components![0] == 1, "Appearance changes still update ink")
    let bitmap = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 2560,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    bitmap.scaleBy(x: 2, y: 2)
    view.layer.render(in: bitmap)
    let bytes = bitmap.data!.assumingMemoryBound(to: UInt8.self)
    precondition(bytes[14 * 2560 + 80 * 4 + 3] > 170, "Retina dots retain their coverage")
    precondition(bytes[18 * 2560 + 80 * 4 + 3] == 0, "Retina grid retains its dotted gaps")
    view.update(primary: [40.25, 80.25], secondary: [120.25], primaryColor: CGColor(gray: 1, alpha: 1),
                secondaryColor: CGColor(gray: 0.5, alpha: 1), scale: 2, strokeWidth: 0.5, dashed: false)
    precondition(layers[0].path === primary && layers[0].lineWidth == 0.25 && layers[0].lineDashPattern == nil,
                 "The continuous grid style updates without rebuilding geometry")
    bitmap.clear(CGRect(x: 0, y: 0, width: 320, height: 180))
    view.layer.render(in: bitmap)
    precondition(bytes[18 * 2560 + 80 * 4 + 3] > 110, "Continuous lines fill the former dotted gaps")
    view.frame.size.height = 240; view.setNeedsLayout(); view.layoutIfNeeded()
    precondition(layers[0].path !== primary && layers[0].path!.boundingBox.maxY == 240, "iPad resize must redraw line lengths")
    update([])
    precondition(layers[0].path!.isEmpty && !view.isUserInteractionEnabled, "Hidden grid clears without intercepting editing gestures")
    precondition(view.layer.sublayers!.count == 2, "Retained layer count stays bounded")
    precondition(layers.allSatisfy { $0.animationKeys()?.isEmpty != false }, "Grid must not animate behind a zoom gesture")
    #endif
    print("TIMELINE_GRID_INK_REUSE_INVALIDATION_RETINA_AND_BOUNDED_LAYERS_OK")
}
