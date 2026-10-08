MainActor.assumeIsolated {
    let window = NSWindow(contentRect: CGRect(x: -10000, y: 0, width: 800, height: 240),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 240))
    window.contentView = host
    let needles = NativeTimelineNeedlesView(frame: CGRect(x: 0, y: 0, width: 10000, height: 240))
    host.addSubview(needles)
    let show = ShowController()
    show.publish(main: 100)
    func configure(_ controller: ShowController) {
        needles.configure(show: controller, size: CGSize(width: 10000, height: 240), rulerHeight: 48,
            verticalOffset: 0, extent: 1000, seek: { _, _ in }, marker: { _ in })
    }
    func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
    func freezeAutomaticTimer() { needles.freezeTimerForTest() }
    func position(_ index: Int) -> Double { needles.layer!.sublayers![index].position.x / 10 }
    configure(show); freezeAutomaticTimer(); drain(); freezeAutomaticTimer()
    precondition(needles.timerIntervalForTest == 1.0 / 60.0, "presentation cadence must remain 60 Hz")
    let initialPaints = needles.paintCountForTest
    var samples = 0
    for frame in 0..<60 {
        if frame % 2 == 0 {
            let before = needles.paintCountForTest
            show.publish(main: 100 + Double(frame) / 60, tick: true)
            drain()
            precondition(needles.paintCountForTest == before,
                "routine 30 Hz snapshots must update the sample without inserting another paint")
            precondition(needles.sampleTimeForTest == show.timelinePlaybackSampleTime,
                "authoritative position and epoch must remain paired before the next frame")
            samples += 1
        }
        needles.fireFrameForTest()
        let sampledPosition = show.snapshot.transport.position
        precondition(position(1) >= sampledPosition && position(1) <= sampledPosition + TimelinePlaybackPresentation.maximumExtrapolation,
            "every frame uses the latest sample and preserves bounded interpolation")
    }
    precondition(samples == 30 && needles.paintCountForTest - initialPaints == 60,
        "30 transport publications plus 60 display ticks must produce 60 paints, not 90")
    var transitions = 0
    func immediate(_ label: String, _ update: () -> Void) {
        let before = needles.paintCountForTest
        update(); drain(); freezeAutomaticTimer()
        precondition(needles.paintCountForTest == before + 1, "immediate needle presentation: \(label)")
        transitions += 1
    }
    @MainActor func engineUpdate(_ update: (inout TransportState) -> Void) {
        show.timelinePlaybackIsPublishingTick = true
        show.resetSampleClockForTest()
        update(&show.snapshot.transport)
        show.timelinePlaybackIsPublishingTick = false
    }
    immediate("explicit edit seek while playing") {
        show.snapshot.transport.editPosition = 140.25
    }
    precondition(position(0) == 140.25)
    immediate("explicit sub seek below any discontinuity threshold") {
        show.snapshot.transport.subPlay.position += 0.0001
    }
    immediate("sub handoff inside engine tick") {
        engineUpdate { $0.subPlay.playing = true; $0.subPlay.position = 42 }
    }
    precondition(!needles.layer!.sublayers![2].isHidden)
    immediate("sub promotion inside engine tick") {
        engineUpdate { $0.subPlay.playing = false; $0.subPlayPromotion = 1; $0.position = 42 }
    }
    immediate("region transition inside engine tick") { engineUpdate { $0.regionId = UUID() } }
    immediate("loop boundary inside engine tick") {
        engineUpdate { $0.loop = LoopState(enabled: true, start: 40, end: 45) }
    }
    immediate("loop wrap inside engine tick") {
        engineUpdate { $0.sectionJumpSerial = 1; $0.position = 40.01 }
    }
    immediate("unannounced backwards engine transition") { engineUpdate { $0.position = 39.99 } }
    immediate("multi-loop boundary inside engine tick") {
        engineUpdate { $0.multiLoop = MultiLoopPlayback(id: UUID(), start: 39, end: 44,
            amount: 0, gates: false, released: false, tracks: []) }
    }
    let beforeAmount = needles.paintCountForTest
    engineUpdate { $0.multiLoop?.amount = 0.5 }; drain()
    precondition(needles.paintCountForTest == beforeAmount,
        "routine multi-loop amount changes cannot add a second presentation cadence")
    immediate("multi-loop release inside engine tick") { engineUpdate { $0.multiLoop?.released = true } }
    immediate("ignore-next boundary inside engine tick") { engineUpdate { $0.ignoreNextEnd = 46 } }
    immediate("pause inside engine tick") { engineUpdate { $0.playing = false; $0.paused = true } }
    precondition(!needles.hasTimerForTest && !needles.layer!.sublayers![1].isHidden)
    immediate("stopped edit seek") { show.snapshot.transport.editPosition = 333.125 }
    precondition(position(0) == 333.125)
    immediate("sub preview start") { show.subCursorPreview = true }
    precondition(needles.hasTimerForTest)
    immediate("sub preview stop") { show.subCursorPreview = false }
    precondition(!needles.hasTimerForTest)
    immediate("resume inside engine tick") { engineUpdate { $0.playing = true; $0.paused = false } }
    precondition(needles.hasTimerForTest)
    // An immediate command must dominate an already queued routine sample.
    immediate("stop coalesced with queued tick") {
        show.publish(main: 44, tick: true)
        show.publish(main: 45, playing: false)
    }
    precondition(!needles.hasTimerForTest && needles.layer!.sublayers![1].isHidden && position(0) == 45)
    let beforeProjection = needles.paintCountForTest
    needles.updateProjection(size: CGSize(width: 20000, height: 240), rulerHeight: 64, extent: 1000)
    precondition(needles.paintCountForTest == beforeProjection + 1 && position(0) == 90,
        "explicit geometry projects immediately without a transport or frame tick")
    configure(show); drain(); freezeAutomaticTimer()
    immediate("restart") { show.publish(main: 100) }
    show.publish(main: 101, tick: true)
    let beforeDetach = needles.paintCountForTest
    needles.removeFromSuperview()
    precondition(!needles.hasTimerForTest && needles.paintCountForTest == beforeDetach + 1 && position(1) >= 101,
        "detachment samples the latest completed transport and stops its frame clock")
    drain()
    let beforeAttach = needles.paintCountForTest
    host.addSubview(needles); freezeAutomaticTimer()
    precondition(needles.hasTimerForTest && needles.paintCountForTest == beforeAttach + 1,
        "reattachment immediately paints and restarts the same 60 Hz clock")
    let replacement = ShowController(); replacement.publish(main: 700, playing: false)
    show.publish(main: 102, tick: true)
    configure(replacement)
    precondition(position(0) == 700 && !needles.hasTimerForTest,
        "controller/project replacement wins immediately over the old pending sample")
    drain(); precondition(position(0) == 700)
    immediate("new controller song transition") {
        replacement.snapshot.transport.songId = UUID()
        replacement.snapshot.transport.editPosition = 701
    }
    precondition(position(0) == 701)
    replacement.publish(main: 702, tick: true)
    needles.stop()
    let beforeStoppedDrain = needles.paintCountForTest
    drain()
    precondition(!needles.hasTimerForTest && needles.paintCountForTest == beforeStoppedDrain,
        "teardown cancels pending publication work and cannot repaint a stale controller")
    window.orderOut(nil); window.close()
    print("NATIVE_NEEDLES_SINGLE_CADENCE_OK snapshots=30 frames=60 paints=60 immediateTransitions=\(transitions) visibilityAndReplacement=true")
}

MainActor.assumeIsolated {
    let window = NSWindow(contentRect: CGRect(x: -10000, y: 0, width: 800, height: 240),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let show = ShowController(); show.publish(main: 100)
    let host = NeedleHostingView(rootView: NativeTimelineNeedles(show: show, width: 10000, height: 240,
        rulerHeight: 48, verticalOffset: 0, extent: 1000, seek: { _, _ in }, marker: { _ in })
        .frame(width: 10000, height: 240))
    window.contentView = host; host.layoutSubtreeIfNeeded()
    func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
    func find(_ view: NSView) -> NativeTimelineNeedlesView? {
        if let needles = view as? NativeTimelineNeedlesView { return needles }
        return view.subviews.lazy.compactMap(find).first
    }
    pump()
    let needles = find(host)!
    needles.freezeTimerForTest(); pump(); needles.freezeTimerForTest()
    let configurations = needles.configureCountForTest, paints = needles.paintCountForTest
    for tick in 0..<30 {
        let before = needles.paintCountForTest
        show.publish(main: 100 + Double(tick) / 30, tick: true); pump()
        precondition(needles.paintCountForTest == before,
            "real SwiftUI hosting must not add a snapshot paint outside the frame clock")
        needles.fireFrameForTest(); needles.fireFrameForTest()
    }
    precondition(needles.paintCountForTest - paints == 60 && needles.configureCountForTest == configurations,
        "the real representable retains configure count across 30 routine snapshots and paints precisely 60 frames")
    needles.stop(); window.orderOut(nil); window.close()
    print("NATIVE_NEEDLES_HOSTED_CADENCE_OK snapshots=30 frames=60 paints=60 extraConfigureCalls=0")
}
