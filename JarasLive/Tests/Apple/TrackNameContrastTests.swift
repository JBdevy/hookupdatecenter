import AppKit
import SwiftUI

let opaqueCases: [(UInt32, UInt32)] = [
    (0x000000, 0xffffff), (0xffffff, 0x000000),
    (0xff0000, 0x000000), (0x00ff00, 0x000000), (0x0000ff, 0xffffff),
    (0xffdc52, 0x000000), (0x757575, 0xffffff), (0x767676, 0x000000)
]
for (background, expected) in opaqueCases {
    precondition(TrackNameContrast.foreground(background, opacity: 1, background: 0) == expected)
}
precondition(TrackNameContrast.foreground(0xff0000, opacity: 0.5, background: 0x202630) == 0xffffff, "a dark translucent red row needs white, even though opaque red prefers black")
precondition(TrackNameContrast.foreground(0xff0000, opacity: 0.95, background: 0x202630, emphasized: true) == 0x000000, "selection must recalculate the name against its stronger background")
precondition(TrackNameContrast.foreground(0xffdc52, opacity: 0.5, background: 0x1b212a) == 0x000000, "the default Master yellow needs a black name")
precondition(TrackNameContrast.foreground(0xffffff, opacity: 0, background: 0x202630) == 0xffffff)
precondition(abs(TrackNameContrast.luminance(red: 0, green: 0, blue: 0)) < 1e-12)
precondition(abs(TrackNameContrast.luminance(red: 1, green: 1, blue: 1) - 1) < 1e-12)

@MainActor func verifyRenderedBackgrounds() {
    let colors: [UInt32] = [0, 0xffffff, 0xffdc52, 0xff0000, 0x00ff00, 0x0000ff, 0x777777, 0x747474, 0x969ed7, 0x8ed2e1, 0x80b760]
    for hex in colors {
        for selected in [false, true] {
            for silenced in [false, true] {
                let color = TrackNameContrast.components(hex, emphasized: selected)
                let base = TrackNameContrast.components(0x202630)
                let layer = Color(red: color.red, green: color.green, blue: color.blue)
                    .opacity(selected ? 0.95 : 0.5).saturation(silenced ? 0 : 1)
                    .background(Color(red: base.red, green: base.green, blue: base.blue))
                    .frame(width: 8, height: 8)
                let renderer = ImageRenderer(content: layer)
                renderer.scale = 1
                let image = renderer.cgImage!
                var bytes = [UInt8](repeating: 0, count: 8 * 8 * 4)
                bytes.withUnsafeMutableBytes { raw in
                    let context = CGContext(data: raw.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8))
                }
                let luminance = TrackNameContrast.luminance(red: Double(bytes[0]) / 255, green: Double(bytes[1]) / 255, blue: Double(bytes[2]) / 255)
                let black = (luminance + 0.05) / 0.05, white = 1.05 / (luminance + 0.05)
                let foreground = TrackNameContrast.foreground(hex, opacity: selected ? 0.95 : 0.5, background: 0x202630, emphasized: selected, desaturated: silenced)
                precondition(foreground == (black >= white ? 0 : 0xffffff), "the name must use the better contrast against actual SwiftUI-composited pixels")
                precondition(max(black, white) >= 4.5, "normal track names require readable contrast")
            }
        }
    }
}

extension TrackDragTitleView {
    fileprivate func fixtureLabel() -> NSAttributedString { label() }
}
MainActor.assumeIsolated {
    verifyRenderedBackgrounds()
    let title = TrackDragTitleView(frame: CGRect(x: 0, y: 0, width: 200, height: 16))
    title.title = "01  Piano"
    title.foreground = 0
    let black = title.fixtureLabel()
    precondition(black.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .black)
    precondition(title.fixtureLabel() === black, "unchanged titles reuse their attributed text")
    title.foreground = 0xffffff
    let white = title.fixtureLabel()
    precondition(white !== black && white.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .white, "selection/color changes must invalidate a reused native title's color")
    title.foreground = 0xffffff
    precondition(title.fixtureLabel() === white)
}
print("TRACK_NAME_CONTRAST_COMPOSITING_SELECTION_MUTE_MASTER_AND_NATIVE_CACHE_OK")
