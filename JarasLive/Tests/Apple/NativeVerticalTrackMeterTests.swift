import Foundation

@MainActor func run() {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 80, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 80, height: 100))
    let document = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 10_000))
    scroll.documentView = document; window.contentView = scroll
    let level = TrackMeterLevel(), meter = NativeVerticalTrackMeterView(frame: NSRect(x: 5, y: 0, width: 32, height: 80))
    meter.bind(level, showScale: true); document.addSubview(meter)
    window.orderFront(nil)
    scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
    precondition(meter.visibleRect.height == 80, "meter fixture must intersect the native viewport")
    func coloredPixels(_ x: Int) -> Int {
        let image = meter.bitmapImageRepForCachingDisplay(in: meter.bounds)!
        meter.cacheDisplay(in: meter.bounds, to: image)
        let scale = Double(image.pixelsWide) / Double(meter.bounds.width)
        return (0..<image.pixelsHigh).filter { y in
            guard let color = image.colorAt(x: Int(Double(x) * scale), y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return max(color.redComponent, max(color.greenComponent, color.blueComponent)) > 0.5
        }.count
    }
    window.contentView?.layoutSubtreeIfNeeded(); meter.layoutSubtreeIfNeeded()
    meter.needsDisplay = false
    precondition(!meter.needsLayout, "finish initial AppKit layout before measuring ticks")
    level.update(left: 1, right: 0, elapsed: 1)
    precondition(meter.needsDisplay && !meter.needsLayout, "level updates invalidate visible pixels, never layout: display \(meter.needsDisplay), layout \(meter.needsLayout)")
    precondition(coloredPixels(2) > 50 && coloredPixels(7) == 0, "native drawing must preserve independent left/right levels")
    level.reset(); level.update(left: 0, right: 1, elapsed: 1)
    precondition(coloredPixels(2) == 0 && coloredPixels(7) > 50, "native drawing must preserve the right channel independently")
    meter.layoutSubtreeIfNeeded(); meter.needsDisplay = false
    precondition(meter.hitTest(NSPoint(x: 2, y: 30)) == nil, "meters must never intercept selection, drag or right click")
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 300)); scroll.reflectScrolledClipView(scroll.contentView)
    precondition(meter.visibleRect.isEmpty, "fixture must fully clip the meter")
    meter.needsDisplay = false
    level.reset(); level.update(left: 0.1, right: 0.5, elapsed: 1)
    precondition(!meter.needsDisplay && !meter.needsLayout, "offscreen level ticks must not invalidate drawing or layout")
    scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
    precondition(meter.needsDisplay, "revealing an offscreen meter must redraw its latest cached levels")
    precondition(coloredPixels(2) < coloredPixels(7), "reveal must show current stereo values rather than old cached pixels")
    meter.bind(level, showScale: false)
    level.reset(); precondition(coloredPixels(2) == 0 && coloredPixels(7) == 0, "silence clears both cached channels")
    let replacement = TrackMeterLevel()
    replacement.update(left: 1, right: 0, elapsed: 1)
    meter.bind(replacement, showScale: true)
    precondition(coloredPixels(2) > 50 && coloredPixels(7) == 0, "rebinding reads the current replacement level")
    meter.needsDisplay = false
    level.update(left: 1, right: 1, elapsed: 1)
    precondition(coloredPixels(2) > 50 && coloredPixels(7) == 0, "rebinding must cancel the previous meter subscription and keep replacement pixels")

    var offscreenLevels: [TrackMeterLevel] = [], offscreenViews: [NativeVerticalTrackMeterView] = []
    for index in 0..<95 {
        let model = TrackMeterLevel()
        let view = NativeVerticalTrackMeterView(frame: NSRect(x: 5, y: CGFloat(index + 1) * 90 + 100, width: 32, height: 80))
        document.addSubview(view); view.bind(model, showScale: true)
        view.layoutSubtreeIfNeeded(); view.needsDisplay = false
        offscreenLevels.append(model); offscreenViews.append(view)
    }
    window.contentView?.layoutSubtreeIfNeeded()
    for view in offscreenViews { view.layoutSubtreeIfNeeded(); view.needsDisplay = false }
    let start = ProcessInfo.processInfo.systemUptime
    for tick in 0..<300 {
        let amplitude = tick.isMultiple(of: 2) ? 1.0 : 0.1
        for model in offscreenLevels { model.update(left: amplitude, right: amplitude / 2, elapsed: 1) }
    }
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    precondition(offscreenViews.allSatisfy { !$0.needsDisplay && !$0.needsLayout }, "95 offscreen meters must cause zero draw/layout invalidations across 300 ticks")
    window.orderOut(nil)
    let hiddenDrawingState = meter.needsDisplay, hiddenLayoutState = meter.needsLayout
    replacement.reset()
    precondition(meter.needsDisplay == hiddenDrawingState && meter.needsLayout == hiddenLayoutState, "hidden-window level changes must not add AppKit invalidations")
    print("NATIVE_STEREO_METER_DRAW_VISIBLE_CLIP_REVEAL_SUBSCRIPTION_AND_ZERO_OFFSCREEN_LAYOUT_OK")
    print("NATIVE_METER_95_OFFSCREEN_300_TICKS_MS=\(elapsed * 1_000) per_tick_ms=\(elapsed * 1_000 / 300)")
}
MainActor.assumeIsolated { run() }
