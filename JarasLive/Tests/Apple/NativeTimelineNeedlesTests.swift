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
    let initialLayouts = host.layouts
    show.publish(main: 20); pump(0.035)
    let first = position(1); pump(0.02); let second = position(1)
    precondition(first >= 20 && second > first, "native layers interpolate between authoritative samples")
    pump(0.1)
    let stable = position(1)
    for _ in 0..<6 { show.resetSampleClockForTest(); pump(0.015) }
    precondition(position(1) >= stable - 0.00001, "clock resets cannot pull an old sample backwards")
    precondition(host.layouts == initialLayouts, "moving needles must not request SwiftUI document layout")
    print("NATIVE_NEEDLES_INTERPOLATION_EPOCH_AND_NO_HOST_LAYOUT_OK")
    func expectOrigin(_ position: Double) {
        let minimum = position * 10 - scroll.contentView.bounds.width / 2
        precondition(scroll.contentView.bounds.minX >= minimum - 0.00001 && scroll.contentView.bounds.minX <= minimum + 1,
            "native scroll follows the active needle")
    }
    show.publish(main: 700, sub: 120, subPlaying: true); pump(0.12); expectOrigin(120)
    precondition(!needles.layer!.sublayers![2].isHidden, "Sub Play is visible")
    show.publish(main: 800, sub: 130, subPlaying: true); pump(0.12); expectOrigin(130)
    show.publish(main: 300, sub: 130, subPlaying: false); pump(0.12); expectOrigin(300)
    show.publish(main: 500, playing: false); pump(0.12)
    let origin = scroll.contentView.bounds.minX
    pump(0.12); precondition(scroll.contentView.bounds.minX == origin)
    precondition(needles.layer!.sublayers![1].isHidden, "stopped head is hidden")
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
    needles.stop()
}
