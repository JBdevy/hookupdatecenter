@MainActor private final class NeedleHostingView<Content: View>: NSHostingView<Content> {
    var layouts = 0
    override func layout() { layouts += 1; super.layout() }
}
MainActor.assumeIsolated {
    setbuf(stdout, nil)
    let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
    let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 800, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let scroll = GridNativeScrollView(frame: CGRect(x: 0, y: 0, width: 800, height: 240))
    scroll.contentView = TimelineClipView(); scroll.borderType = .noBorder
    scroll.horizontalScrollElasticity = .none; scroll.verticalScrollElasticity = .none
    let show = ShowController()
    var seeks: [(Double, Bool)] = []
    let host = NeedleHostingView(rootView: NativeTimelineNeedles(show: show, width: 10000, height: 240,
        rulerHeight: 48, verticalOffset: 0, extent: 1000, seek: { seeks.append(($0, $1)) }, marker: { _ in }).frame(width: 10000, height: 240))
    host.frame = CGRect(x: 0, y: 0, width: 10000, height: 240)
    window.contentView = scroll; scroll.documentView = host; scroll.tile(); window.orderFrontRegardless()
    defer { window.orderOut(nil); window.close() }
    func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    func find(_ view: NSView) -> NativeTimelineNeedlesView? {
        if let needles = view as? NativeTimelineNeedlesView { return needles }
        return view.subviews.lazy.compactMap(find).first
    }
    pump(0.2)
    let needles = find(host)!
    func position(_ index: Int) -> Double { (needles.layer!.sublayers![index].frame.minX + 14) / 10 }
    func unchangedProjection() {
        needles.updateProjection(size: CGSize(width: 10000, height: 240), rulerHeight: 48, extent: 1000)
    }
    let initialLayouts = host.layouts
    show.publish(main: 20); pump(0.035)
    let first = position(1)
    usleep(4_000)
    unchangedProjection()
    precondition(position(1) == first,
                 "unchanged projection must not interpolate and reschedule follow between timer ticks")
    pump(0.02); let second = position(1)
    precondition(needles.layer!.sublayers![1].animationKeys()?.isEmpty != false,
                 "playback positions update directly without implicit animation lag")
    precondition(first >= 20 && second > first, "native layers interpolate between authoritative samples")
    pump(0.1)
    let stable = position(1)
    for _ in 0..<6 { show.resetSampleClockForTest(); unchangedProjection(); pump(0.015) }
    precondition(position(1) >= stable - 0.00001, "clock resets cannot pull an old sample backwards")
    precondition(host.layouts == initialLayouts, "moving needles must not request SwiftUI document layout")
    print("NATIVE_NEEDLES_INTERPOLATION_EPOCH_AND_NO_HOST_LAYOUT_OK")
    func expectOrigin(_ position: Double) {
        let minimum = position * 10 - scroll.contentView.bounds.width / 2
        precondition(scroll.contentView.bounds.minX >= minimum - 0.00001 && scroll.contentView.bounds.minX <= minimum + 1,
            "native scroll follows the active needle")
    }
    show.publish(main: 700, sub: 120, subPlaying: true); unchangedProjection(); pump(0.12); expectOrigin(120)
    precondition(!needles.layer!.sublayers![2].isHidden, "Sub Play is visible")
    show.publish(main: 800, sub: 130, subPlaying: true); unchangedProjection(); pump(0.12); expectOrigin(130)
    show.publish(main: 300, sub: 130, subPlaying: false); unchangedProjection(); pump(0.12); expectOrigin(300)
    show.publish(main: 500, playing: false); unchangedProjection(); pump(0.12)
    let origin = scroll.contentView.bounds.minX
    pump(0.12); precondition(scroll.contentView.bounds.minX == origin)
    precondition(needles.layer!.sublayers![1].isHidden, "stopped head is hidden")
    show.snapshot.transport.paused = true; unchangedProjection(); pump(0.03)
    precondition(!needles.layer!.sublayers![1].isHidden && position(1) == 500,
                 "pause publications update the main head with identical projection geometry")
    show.publish(main: 140, playing: false); unchangedProjection(); pump(0.03)
    precondition(position(0) == 140 && needles.layer!.sublayers![1].isHidden,
                 "a stopped seek updates the editing head with identical projection geometry")
    needles.updateProjection(size: CGSize(width: 20000, height: 240), rulerHeight: 64, extent: 1000)
    precondition(position(0) == 280, "a changed projection immediately updates the head's document position")
    unchangedProjection()
    precondition(position(0) == 140, "restoring the projection updates immediately without a transport event")
    show.publish(main: 500, playing: false); unchangedProjection(); pump(0.03)
    print("NATIVE_NEEDLES_UNCHANGED_PROJECTION_TIMER_EPOCH_PAUSE_SEEK_AND_ZOOM_OK")
    let pausedLayouts = host.layouts
    let editLine = needles.layer!.sublayers![0].sublayers![1] as! CAShapeLayer
    let previousColor = editLine.strokeColor
    AppearanceColor.shared("jaras.timeline.editCursor", default: 0).value = 0xff0000; pump(0.03)
    precondition(editLine.strokeColor != previousColor, "user appearance updates without SwiftUI ticks")
    let local = CGPoint(x: position(0) * 10, y: 40)
    let point = needles.convert(local, to: nil)
    let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    needles.mouseDown(with: event); needles.mouseUp(with: event)
    precondition(seeks.last?.1 == false && abs(seeks.last!.0 - 500) < 0.00001, "editing head remains draggable")
    precondition(host.layouts == pausedLayouts, "appearance and head interaction do not relayout the host")
    print("NATIVE_NEEDLES_SUB_PRIORITY_CANCEL_STOP_APPEARANCE_AND_EDIT_HIT_OK")
    // At the furthest zoom the song and its cursors occupy only a few pixels.
    // Verify the real compositor geometry and painted alpha, not just positions.
    for extent in [1000.0, 200000, 1000000] {
        needles.configure(show: show, size: CGSize(width: 800, height: 240), rulerHeight: 48,
            verticalOffset: 0, extent: extent, seek: { _, _ in }, marker: { _ in })
        let root = needles.layer!.sublayers![0]
        precondition((root.sublayers![1] as! CAShapeLayer).bounds.size == CGSize(width: 28, height: 240))
        let bitmap = CGContext(data: nil, width: 800, height: 240, bitsPerComponent: 8,
            bytesPerRow: 800 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        needles.layer!.render(in: bitmap)
        let pixels = bitmap.data!.assumingMemoryBound(to: UInt8.self)
        let column = Int(min(799, max(0, 500 * 800 / extent)))
        let left = max(0, column - 2), right = min(799, column + 2)
        precondition((left...right).contains { pixels[100 * 800 * 4 + $0 * 4 + 3] > 0 },
                     "the editing needle remains painted at every zoom level")
    }
    print("NATIVE_NEEDLES_VISIBLE_PIXELS_AT_DISTANT_AND_MINIMUM_ZOOM_OK")
    for width in [1000000.0, 100000, 12000, 1500] {
        host.rootView = NativeTimelineNeedles(show: show, width: width, height: 240,
            rulerHeight: 48, verticalOffset: 0, extent: 1000,
            seek: { _, _ in }, marker: { _ in }).frame(width: width, height: 240)
        host.setFrameSize(CGSize(width: width, height: 240)); host.layoutSubtreeIfNeeded()
        show.publish(main: 500, playing: true); pump(0.25)
        let current = find(host)!
        precondition(abs(current.frame.width - width) < 0.001,
            "zooming out must shrink the native needle host, rather than center its stale fitting width")
        let head = current.layer!.sublayers![1]
        let actualX = current.convert(CGPoint(x: head.frame.minX + 14, y: 50), to: host).x
        precondition(abs(actualX - (500 + TimelinePlaybackPresentation.maximumExtrapolation) * width / 1000) < 1,
            "the composited playback needle must occupy the same document coordinate as the items")
        precondition(current.visibleRect.intersects(head.frame), "the playback needle must remain inside the visible native viewport after zoom")
    }
    print("NATIVE_NEEDLES_SWIFTUI_HOST_SHRINK_AND_DOCUMENT_ALIGNMENT_OK")
    needles.stop()

    // Production pins the native needle view vertically. A scroll must move
    // that host immediately even when stopped, with no timer or extra paint.
    let pinnedWindow = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 800, height: 240),
        styleMask: [.titled], backing: .buffered, defer: false)
    pinnedWindow.isReleasedWhenClosed = false
    let outer = GridNativeScrollView(frame: CGRect(x: 0, y: 0, width: 800, height: 240))
    let inner = GridNativeScrollView(frame: CGRect(x: 0, y: 0, width: 800, height: 800))
    let document = NativeTimelinePinnedView(frame: CGRect(x: 0, y: 0, width: 10000, height: 800))
    let pin = NativeTimelinePinnedView(frame: document.bounds)
    let pinnedNeedles = NativeTimelineNeedlesView(frame: document.bounds)
    let stopped = ShowController()
    pinnedNeedles.configure(show: stopped, size: document.bounds.size, rulerHeight: 48,
        verticalOffset: 0, extent: 1000, seek: { _, _ in }, marker: { _ in })
    pin.host = pinnedNeedles; pin.addSubview(pinnedNeedles); document.addSubview(pin)
    inner.documentView = document; outer.documentView = inner
    pinnedWindow.contentView = outer; outer.tile(); inner.tile(); pin.observeScroll()
    pinnedWindow.orderFrontRegardless(); pump(0.03)
    let tip = CGPoint(x: 1000, y: 48)
    let screenY = pinnedNeedles.convert(tip, to: nil).y
    let layerPosition = pinnedNeedles.layer!.sublayers![0].position
    for y: CGFloat in [150, 350, 40, 0] {
        outer.contentView.scroll(to: CGPoint(x: 0, y: y))
        pinnedNeedles.updateProjection(size: document.bounds.size, rulerHeight: 48, extent: 1000)
        precondition(pinnedNeedles.frame.minY == outer.contentView.bounds.minY,
                     "vertical scrolling pins the native host synchronously while stopped")
        precondition(abs(pinnedNeedles.convert(tip, to: nil).y - screenY) < 0.001 &&
                     pinnedNeedles.layer!.sublayers![0].position == layerPosition,
                     "vertical pinning preserves the screen position without repainting needle geometry")
    }
    pinnedNeedles.stop(); pinnedWindow.orderOut(nil); pinnedWindow.close()
    print("NATIVE_NEEDLES_VERTICAL_PINNING_WITH_UNCHANGED_PROJECTION_AND_STOPPED_TIMER_OK")
}
