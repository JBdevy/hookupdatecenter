var viewport = IpadTimelineViewport()
viewport.reset(duration: 1200)
require(viewport.start == 0 && viewport.span == 300, "Long projects begin with a useful free viewport")
viewport.pan(pixels: -400, width: 400)
require(viewport.start == 300 && viewport.end == 600, "Horizontal scroll reaches another region without selecting it")
let anchor = viewport.start + viewport.span * 0.25
viewport.zoom(factor: 4, anchor: 0.25)
require(viewport.span == 75 && abs(viewport.start + viewport.span * 0.25 - anchor) < 0.00001, "Pinch preserves the touched timeline point")
viewport.zoom(factor: 0.25, anchor: 0.25)
require(viewport.start == 300 && viewport.span == 300, "Zoom reverses without shifting content")
viewport.pan(pixels: -4000, width: 400)
require(viewport.start > 1200, "A native project can scroll into free grid beyond its last item")
let previous = viewport
viewport.zoom(factor: .nan, anchor: 0.5); viewport.zoom(factor: 0, anchor: 0.5)
viewport.pan(pixels: .infinity, width: 1); viewport.pan(pixels: 1, width: 0)
require(viewport == previous, "Invalid gestures cannot corrupt grid geometry")
viewport.zoom(factor: 1e12, anchor: 0.5)
require(viewport.span == 0.25, "Close zoom has a bounded readable scale")
viewport.zoom(factor: 1e-12, anchor: 0.5)
require(viewport.span == 36000 && viewport.start >= 0, "Wide zoom stops at the ten-hour iPad overview")
viewport.pan(pixels: 1e12, width: 1)
require(viewport.start == 0, "Left scroll stops at timeline origin")
viewport.pan(pixels: -1e12, width: 1)
require(viewport.end == 604800, "Right scroll stays within the transport time domain")
viewport.reset(duration: 0)
require(viewport.span == 30 && viewport.start == 0, "Empty project retains editable free grid")
print("IPAD_STANDALONE_FREE_TIMELINE_PAN_PINCH_ANCHOR_AND_BOUNDS_OK")
viewport.reveal(900)
require(viewport.start <= 900 && viewport.end >= 900 && viewport.span == 30, "Selecting distant song reveals playhead without fitting/changing zoom")
let revealed = viewport
viewport.reveal(901)
require(viewport == revealed, "In-view playback advances the needle without redrawing moving content")
print("IPAD_STANDALONE_SONG_REVEAL_PRESERVES_ZOOM_AND_STATIC_VIEWPORT_OK")
viewport.center(on: 1200)
require(viewport.start + viewport.span / 2 == 1200, "Selecting a song centers its cursor even when it is already visible")
for factor in [1.1, 1.3, 0.8, 1.2, 0.7] {
    viewport.zoom(factor: factor, centeredOn: 1200)
    require(abs(viewport.start + viewport.span / 2 - 1200) < 0.00001, "Repeated pinch updates keep the selected playback/edit cursor centered")
}
let centered = viewport
viewport.zoom(factor: .nan, centeredOn: 1200)
viewport.zoom(factor: 2, centeredOn: .infinity)
require(viewport == centered, "Invalid cursor-centered gestures preserve the viewport")
viewport.center(on: 0)
require(viewport.start == 0, "Centering at the beginning never scrolls before timeline zero")
print("IPAD_CURSOR_CENTERING_AND_RAPID_PINCH_ANCHOR_OK")

viewport = IpadTimelineViewport(start: 100, span: 60)
viewport.follow(129)
require(viewport.start == 100, "Playback does not move the grid before its midpoint")
viewport.follow(131)
require(viewport.start == 101, "Continuous scroll starts immediately beyond the midpoint")
for position in stride(from: 131.0, through: 150.0, by: 0.25) {
    viewport.follow(position)
    require(abs(viewport.start + viewport.span / 2 - position) < 0.00001, "Every playback update keeps the needle at the grid midpoint")
}
viewport.follow(40)
require(viewport.start == 10, "A backward playback jump follows the destination")
print("IPAD_CONTINUOUS_FOLLOW_MIDPOINT_AND_BACKWARD_JUMP_OK")

var ruler = IpadTimelineRulerDrag()
viewport = IpadTimelineViewport(start: 100, span: 60)
ruler.update(translation: 2, width: 600, viewport: &viewport)
require(!ruler.dragged && viewport.start == 100, "Ruler click jitter must not scroll")
ruler.update(translation: -100, width: 600, viewport: &viewport)
require(ruler.dragged && viewport.start == 110, "Ruler drag moves the visible grid")
ruler.update(translation: -200, width: 600, viewport: &viewport)
require(viewport.start == 120, "Ruler updates must not accumulate the total translation twice")
ruler.update(translation: 0, width: 600, viewport: &viewport)
require(ruler.dragged && viewport.start == 100, "Returning to origin stays a drag, not a transport seek")
ruler.reset()
ruler.update(translation: -50, width: 600, viewport: &viewport)
require(viewport.start == 105, "Next ruler drag uses the new viewport origin")
ruler.reset()
print("IPAD_RULER_PAN_CLICK_THRESHOLD_REVERSAL_AND_REPEAT_OK")

viewport = IpadTimelineViewport(start: 1200, span: 36000)
let overview = viewport
let overviewCenter = overview.start + overview.span / 2
for _ in 0..<100 { viewport.zoom(factor: 0.5, anchor: 0.5) }
require(viewport == overview, "Repeated zoom out at the ten-hour limit does not drift")
viewport.zoom(factor: 0.001, centeredOn: overviewCenter)
require(viewport == overview, "Cursor-centered zoom uses the same ten-hour limit")
viewport.zoom(factor: 2, centeredOn: overviewCenter)
require(viewport.span == 18000 && viewport.start + viewport.span / 2 == overviewCenter, "Zoom in responds immediately after reaching the overview limit")
viewport.zoom(factor: 0.001, centeredOn: overviewCenter)
require(viewport == overview, "Zooming back out returns to the same ten-hour overview")
viewport.pan(pixels: -400, width: 400)
require(viewport.start == 37200 && viewport.span == 36000, "The zoom limit still allows scrolling to the rest of a long project")
print("IPAD_TEN_HOUR_OVERVIEW_LIMIT_AND_ANCHOR_STABILITY_OK")

// Playback can advance at display cadence while the item drawing remains
// unchanged for many frames; rebasing must preserve every world coordinate.
for visibleSpan in [0.25, 5.0, 60.0, 300.0, 36000.0] {
    for width in [360.0, 800.0, 1366.0] {
        var visible = IpadTimelineViewport(start: 1000, span: visibleSpan)
        var drawing = IpadTimelineRenderWindow(visible)
        var redraws = 0
        for frame in 0...600 {
            let time = 1000 + visibleSpan / 2 + Double(frame) / 60
            visible.follow(time)
            if drawing.needsRebase(visible) { drawing = IpadTimelineRenderWindow(visible); redraws += 1 }
            let offset = drawing.offset(for: visible, width: width)
            require(offset >= -1e-8 && offset <= width + 1e-8, "Retained drawing covers the complete viewport")
            let screenX = (time - drawing.start) / visible.span * width - offset
            require(abs(screenX - width / 2) < 1e-6, "Needle, item and ruler share the same projection after rebasing")
            let clickX = width * 0.25
            let clickedTime = drawing.start + (clickX + offset) / width * visible.span
            require(abs(clickedTime - (visible.start + visible.span * 0.25)) < 1e-8, "Hit-testing converts through the actual retained offset")
        }
        if visibleSpan >= 60 { require(redraws < 3, "A wide overview does not rebuild waveforms on each display frame") }
    }
}
print("IPAD_RETAINED_SCROLL_CONTINUOUS_PROJECTION_REBASE_AND_HIT_TEST_OK")
