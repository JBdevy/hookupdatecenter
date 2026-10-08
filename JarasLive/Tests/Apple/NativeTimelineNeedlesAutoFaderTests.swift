// The runner inserts the production publication flags, getter and entire tick.
// Only the executor and mixer payload are fixtures; transport scheduling stays real.

private struct AutoFaderTickSnapshot {
    var transport: TransportState
    var nextSongId: UUID?
    var gain: Double = 1
}
@MainActor private final class AutoFaderTickExecutor {
    var transport: TransportState
    var change: ((inout TransportState) -> Void)?
    var fail = false
    init(_ transport: TransportState) { self.transport = transport }
    func advance(_ seconds: Double) {
        if transport.playing { transport.position += seconds }
        if transport.subPlay.playing { transport.subPlay.position += seconds }
        change?(&transport); change = nil
    }
    func playbackSnapshot() throws -> AutoFaderTickSnapshot {
        if fail { throw NSError(domain: "Fixture", code: 1) }
        return AutoFaderTickSnapshot(transport: transport)
    }
}
@MainActor private final class AutoFaderTickController {
__PRODUCTION_FLAGS__
    @Published var snapshot: AutoFaderTickSnapshot {
        didSet {
            // The real project's didSet uses this existing guard. Automated
            // mixer updates must still publish their project notifications.
            if !updatingPlaybackSnapshot && oldValue.gain != snapshot.gain {
                projectNotifications += 1
            }
        }
    }
    var lastTime = ProcessInfo.processInfo.systemUptime
    var isPlaying: Bool { snapshot.transport.playing || snapshot.transport.subPlay.playing }
    let executor: AutoFaderTickExecutor
    var timer: Timer?
    var onStop: () -> Void = {}
    var audioUpdate: (AutoFaderTickSnapshot, Int) -> Void = { _, _ in }
    let audioProjectRevision = 0
    var message = ""
    private(set) var projectNotifications = 0
    init(_ transport: TransportState) {
        snapshot = AutoFaderTickSnapshot(transport: transport)
        executor = AutoFaderTickExecutor(transport)
    }
    private func applyLoopMixer() { snapshot.gain -= 0.001 }
    private func focusPreparedRegion(previous: TransportState) {}
    private func rememberCursor() {}
__PRODUCTION_GETTER__
__PRODUCTION_TICK__
}

MainActor.assumeIsolated {
    let window = NSWindow(contentRect: CGRect(x: -10000, y: 0, width: 800, height: 240),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 240)); window.contentView = host
    let needles = NativeTimelineNeedlesView(frame: CGRect(x: 0, y: 0, width: 10000, height: 240))
    host.addSubview(needles)
    let show = ShowController(); show.publish(main: 100)
    let producer = AutoFaderTickController(show.snapshot.transport)
    needles.configure(show: show, size: needles.frame.size, rulerHeight: 48, verticalOffset: 0,
        extent: 1000, seek: { _, _ in }, marker: { _ in })
    var publicationKinds: [Bool] = [], audioUpdates = 0
    producer.audioUpdate = { _, _ in audioUpdates += 1 }
    // Bridge both real tick publications into the needle's controller fixture.
    // Classification is read from the production getter at publication time.
    let subscription = producer.$snapshot.sink { value in
        let fromTick = producer.timelinePlaybackIsPublishingTick
        publicationKinds.append(fromTick)
        show.timelinePlaybackIsPublishingTick = fromTick
        show.resetSampleClockForTest()
        show.snapshot = PresentationTestSnapshot(transport: value.transport)
        show.timelinePlaybackIsPublishingTick = false
    }
    func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
    needles.freezeTimerForTest(); drain(); needles.freezeTimerForTest()
    publicationKinds.removeAll()
    let initialPaints = needles.paintCountForTest
    for _ in 0..<30 {
        let before = needles.paintCountForTest
        producer.tick(); drain()
        precondition(!producer.timelinePlaybackIsPublishingTick)
        precondition(needles.paintCountForTest == before,
            "automated mixer publication after the transport sample must join the same frame cadence")
        needles.fireFrameForTest(); needles.fireFrameForTest()
    }
    precondition(publicationKinds.count == 60 && publicationKinds.allSatisfy { $0 },
        "both transport and automated mixer publications belong to the complete engine tick")
    precondition(needles.paintCountForTest - initialPaints == 60)
    precondition(producer.projectNotifications == 30 && audioUpdates == 30,
        "presentation coalescing must preserve every real project notification and audio callback")
    @MainActor func transition(_ update: @escaping (inout TransportState) -> Void) {
        let before = needles.paintCountForTest
        producer.executor.change = update
        producer.tick(); drain(); needles.freezeTimerForTest()
        precondition(needles.paintCountForTest == before + 1,
            "state changes during an automated mixer tick retain their immediate presentation")
    }
    transition { $0.regionId = UUID() }
    transition { $0.loop = LoopState(enabled: true, start: 90, end: 110) }
    transition { $0.sectionJumpSerial = 1; $0.position = 90 }
    transition { $0.subPlay.playing = true; $0.subPlay.position = 50 }
    transition { $0.subPlay.playing = false; $0.subPlayPromotion = 1; $0.position = 50; $0.editPosition = 50 }
    let beforeCommand = needles.paintCountForTest
    producer.snapshot.transport.editPosition = 50.00001
    drain()
    precondition(!publicationKinds.last! && needles.paintCountForTest == beforeCommand + 1,
        "an explicit edit outside tick is still immediate, even below any distance threshold")
    producer.executor.fail = true
    producer.tick()
    precondition(!producer.timelinePlaybackIsPublishingTick && !producer.message.isEmpty,
        "a failed engine sample must restore the publication scope")
    producer.executor.fail = false
    transition { $0.playing = false; $0.paused = true }
    precondition(!needles.hasTimerForTest && !needles.layer!.sublayers![1].isHidden,
        "a pause reached inside a mixer tick immediately paints then retires the clock")
    withExtendedLifetime(subscription) {}
    needles.stop(); window.orderOut(nil); window.close()
    print("NATIVE_NEEDLES_AUTO_FADER_CADENCE_OK ticks=30 publications=60 paints=60 projectNotifications=30 audioCallbacks=30 transitions=6")
}
