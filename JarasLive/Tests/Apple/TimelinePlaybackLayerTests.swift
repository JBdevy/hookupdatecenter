// This harness supplies only the controller and song storage. The enclosing
// script extracts the production SwiftUI layer and native scroll implementation.
private struct PresentationTestPart { let id: UUID; let parentRegionID: UUID?; let endTime: Double }
private struct PresentationTestSong { let duration: Double; let parts: [PresentationTestPart] }
private struct PresentationTestSnapshot { var transport: TransportState }

@MainActor private final class ShowController: ObservableObject {
    @Published var snapshot: PresentationTestSnapshot
    var current: PresentationTestSong? = PresentationTestSong(duration: 1000, parts: [])
    private var sampledAt = ProcessInfo.processInfo.systemUptime
    private(set) var generation = 0
    var isPlaying: Bool { snapshot.transport.playing || snapshot.transport.subPlay.playing }
    init() {
        snapshot = PresentationTestSnapshot(transport: TransportState(playing: false, position: 100,
            queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 30)))
    }
    var timelinePlaybackTransport: TransportState { snapshot.transport }
    var timelinePlaybackSampleTime: Double { sampledAt }
    func resetSampleClockForTest() { sampledAt = ProcessInfo.processInfo.systemUptime }
    func publish(main: Double, sub: Double = 30, playing: Bool = true, subPlaying: Bool = false) {
        generation += 1
        sampledAt = ProcessInfo.processInfo.systemUptime
        snapshot = PresentationTestSnapshot(transport: TransportState(playing: playing, position: main,
            queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: subPlaying, position: sub)))
    }
}

@MainActor private final class PresentationJournal {
    struct Frame { let generation: Int; let presentation: TimelinePlaybackPresentation }
    var frames: [Frame] = []
    var parentBodyCount = 0
}

private struct PresentationProbe: NSViewRepresentable {
    let journal: PresentationJournal
    let generation: Int
    let presentation: TimelinePlaybackPresentation
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        journal.frames.append(.init(generation: generation, presentation: presentation))
    }
}

private struct EquatablePresentationParent: View, Equatable {
    let show: ShowController
    let journal: PresentationJournal
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.show === rhs.show }
    var body: some View {
        let _ = { journal.parentBodyCount += 1 }()
        TimelinePlaybackLayer(show: show) { presentation in
            Color.clear
                .background(PresentationProbe(journal: journal, generation: show.generation, presentation: presentation))
                .background(TimelinePlaybackFollow(position: presentation.followPosition, pixelsPerSecond: 10,
                    contentWidth: 10000, source: presentation.followSource == .sub ? "song/sub" : "song/main"))
                .frame(width: 10000, height: 240)
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 800, height: 240),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "CatLive — teste de acompanhamento"
    window.isReleasedWhenClosed = false
    let scroll = GridNativeScrollView(frame: CGRect(x: 0, y: 0, width: 800, height: 240))
    scroll.contentView = TimelineClipView()
    scroll.borderType = .noBorder
    scroll.horizontalScrollElasticity = .none
    scroll.verticalScrollElasticity = .none
    let show = ShowController()
    let journal = PresentationJournal()
    let host = NSHostingView(rootView: EquatablePresentationParent(show: show, journal: journal).equatable())
    host.frame = CGRect(x: 0, y: 0, width: 10000, height: 240)
    window.contentView = scroll
    scroll.documentView = host
    scroll.tile()
    window.orderFrontRegardless()
    defer { window.orderOut(nil); window.close() }
    func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    pump(0.2)
    let parentBodyCount = journal.parentBodyCount
    precondition(parentBodyCount > 0 && !journal.frames.isEmpty, "real SwiftUI layer must be mounted")

    // Warm-up can consume a first display callback. Try a few independent
    // samples, without prescribing a frame count or an exact scheduler rate.
    var interpolatedWithoutPublication = false
    for attempt in 0..<3 {
        let base = 100 + Double(attempt) * 10
        show.publish(main: base)
        let generation = show.generation
        pump(0.18)
        let frames = journal.frames.filter { $0.generation == generation }
        let positions = Set(frames.map { $0.presentation.mainPosition })
        if positions.count > 1 && positions.contains(where: { $0 > base }) {
            interpolatedWithoutPublication = true
            break
        }
    }
    precondition(interpolatedWithoutPublication,
                 "TimelineView must advance between authoritative publications behind an Equatable parent")
    precondition(journal.parentBodyCount == parentBodyCount,
                 "transport observations must not reevaluate the parent track/item tree")
    precondition(scroll.contentView.bounds.minX > 0, "the real representable must scroll the native clip")
    print("PLAYBACK_LAYER_INTERPOLATES_WITHOUT_SNAPSHOT_AND_THROUGH_EQUATABLE_OK")

    // An engine tick can reset its clock before SwiftUI consumes the next
    // snapshot. The already-rendered layer must retain its own sample epoch.
    show.publish(main: 200)
    pump(0.18)
    let stablePosition = journal.frames.last!.presentation.mainPosition
    let beforeClockReset = journal.frames.count
    for _ in 0..<6 { show.resetSampleClockForTest(); pump(0.015) }
    let duringClockReset = journal.frames.dropFirst(beforeClockReset)
    // SwiftUI may coalesce identical capped positions; emitting no new native
    // update is also correct. The unfixed layer emits regressing positions.
    precondition(duringClockReset.allSatisfy { $0.presentation.mainPosition >= stablePosition - 0.00001 },
                 "a new engine clock must not make an older rendered transport sample step backward")
    print("PLAYBACK_LAYER_SAMPLE_EPOCH_COHERENT_OK")

    func expectOrigin(for position: Double, message: String) {
        let origin = scroll.contentView.bounds.minX
        let minimum = max(0, position * 10 - scroll.contentView.bounds.width / 2)
        let maximum = minimum + TimelinePlaybackPresentation.maximumExtrapolation * 10
        precondition(origin >= minimum - 0.00001 && origin <= maximum + 0.00001, message)
    }
    show.publish(main: 250, sub: 100, subPlaying: true)
    pump(0.18)
    precondition(journal.frames.last?.presentation.followSource == .sub)
    expectOrigin(for: 100, message: "Sub Play must take ownership of the viewport")
    show.publish(main: 700, sub: 120, subPlaying: true)
    pump(0.18)
    expectOrigin(for: 120, message: "main playback must never pull the grid away from active Sub Play")
    show.publish(main: 300, sub: 120, subPlaying: false)
    pump(0.18)
    precondition(journal.frames.last?.presentation.followSource == .main)
    expectOrigin(for: 300, message: "cancelling Sub Play must restore main playback")
    let playingOrigin = scroll.contentView.bounds.minX
    show.publish(main: 500, playing: false)
    pump(0.18)
    precondition(journal.frames.last?.presentation.followPosition == nil)
    precondition(abs(scroll.contentView.bounds.minX - playingOrigin) < 0.00001,
                 "paused/stopped playback must invalidate follow without moving the view")
    let pausedCount = journal.frames.count
    pump(0.18)
    precondition(journal.frames.dropFirst(pausedCount).allSatisfy { $0.presentation.mainPosition == 500 && $0.presentation.followPosition == nil },
                 "any unrelated paused view update must keep its exact sampled position")
    precondition(abs(scroll.contentView.bounds.minX - playingOrigin) < 0.00001)
    precondition(journal.parentBodyCount == parentBodyCount)
    print("PLAYBACK_LAYER_NATIVE_SUB_PRIORITY_CANCEL_AND_STOP_OK")
}
