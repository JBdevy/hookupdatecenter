import SwiftUI

let item = GridSelectionItem(id: UUID(), rect: CGRect(x: 100, y: 100, width: 400, height: 80), duration: 20)
for (point, expected) in [(CGPoint(x: 250, y: 145), TimelineItemTouchGesture.Action.move),
                          (CGPoint(x: 101, y: 140), .resize(left: true)),
                          (CGPoint(x: 499, y: 140), .resize(left: false)),
                          (CGPoint(x: 102, y: 116), .fade(left: true)),
                          (CGPoint(x: 498, y: 116), .fade(left: false))] {
    var gesture = TimelineItemTouchGesture(item: item, start: point)
    precondition(gesture.action == expected && !gesture.hasDragged)
    if case .fade = expected { precondition(!gesture.shouldSeek) }
    else { precondition(gesture.shouldSeek) }
    gesture.advance(CGSize(width: 0, height: 8))
    gesture.advance(.zero)
    precondition(gesture.hasDragged && !gesture.shouldSeek, "a touch drag that returns to its origin never seeks")
}
for left in [true, false] {
    let gesture = TimelineItemTouchGesture(item: item, start: .zero, fadeSide: left)
    precondition(gesture.fadeValue(translation: CGSize(width: left ? 800 : -800, height: 0)) == 20,
        "fade must reach the entire expanded item duration")
    precondition(gesture.fadeValue(translation: CGSize(width: left ? -800 : 800, height: 0)) == 0)
    precondition(gesture.fadeValue(translation: CGSize(width: left ? 200 : -200, height: 0)) == 10)
}
var timecode = item; timecode.editable = false; timecode.movable = false
precondition(TimelineItemTouchGesture(item: timecode, start: CGPoint(x: 102, y: 116)).action == .resize(left: true),
    "timecode retains duration edges but no audio fades")
print("IPAD_TOUCH_ITEM_TAP_RELEASE_TRIM_FADE_FULL_DURATION_AND_NO_SEEK_AFTER_DRAG_OK")

MainActor.assumeIsolated {
    var visual = item
    visual.rect = CGRect(x: 0, y: 0, width: 400, height: 80)
    visual.fadeIn = 10; visual.fadeOut = 10
    let renderer = ImageRenderer(content: TimelineTouchFadeCurves(item: visual).frame(width: 400, height: 80))
    renderer.scale = 1
    let image = renderer.cgImage!
    let bitmap = NSBitmapImageRep(cgImage: image)
    // Fade endpoints and curved midpoints are real foreground pixels; no Metal
    // source geometry or gain transform is involved in this overlay.
    for point in [CGPoint(x: 1, y: 77), CGPoint(x: 100, y: 45), CGPoint(x: 200, y: 14), CGPoint(x: 300, y: 45), CGPoint(x: 398, y: 77)] {
        var found = false
        for dy in -2...2 { for dx in -2...2 {
            let x = min(399, max(0, Int(point.x) + dx)), y = min(79, max(0, Int(point.y) + dy))
            if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.5, color.redComponent > 0.7 { found = true }
        } }
        precondition(found, "fade curve must remain visible above waveform at \(point)")
    }
}
print("IPAD_FADE_OVERLAY_CURVE_PIXEL_RENDER_OK")
