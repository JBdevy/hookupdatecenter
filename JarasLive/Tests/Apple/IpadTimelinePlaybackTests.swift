// Storage only is stubbed; UIKit scrolling, needle layers and projection below
// are extracted from the actual application by test-ipad-playback-surface.py.
struct PresentationTestPart { let id: UUID; let parentRegionID: UUID?; let endTime: Double }
struct PresentationTestSong { let id = UUID(); let duration: Double; let parts: [PresentationTestPart] }
struct PresentationTestProject { let id = UUID() }
struct PresentationTestSnapshot { var project = PresentationTestProject(); var transport: TransportState }
@MainActor final class ShowController: ObservableObject {
    @Published var snapshot = PresentationTestSnapshot(transport: TransportState(playing: true, position: 130,
        queue: QueueState(), loop: LoopState(enabled: false), subPlay: SubPlayState(playing: false, position: 300)))
    var current: PresentationTestSong? = .init(duration: 1000, parts: [])
    var timelineFollowPaused = false
    var timelinePlaybackSampleTime: Double { ProcessInfo.processInfo.systemUptime }
    var timelinePlaybackTransport: TransportState { snapshot.transport }
}
extension IpadTimelinePlaybackController {
    func frameForTest(elapsed: Double) { sample(); sampledAt -= elapsed; paint() }
    var scrollOffsetForTest: Double { scroll.contentOffset.x - host.view.transform.tx }
    var needleXForTest: Double { main.layer.position.x }
    var subXForTest: Double { sub.layer.position.x }
    var mainHiddenForTest: Bool { main.layer.isHidden }
    var hasClockForTest: Bool { displayLink != nil }
    var preferredCadenceForTest: Int { displayLink?.preferredFramesPerSecond ?? 0 }
    var hostingViewForTest: UIView { host.view }
}
@MainActor @main final class PlaybackTestApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Playback tests", sessionRole: session.role)
        configuration.delegateClass = PlaybackTestScene.self; return configuration
    }
}
@MainActor final class PlaybackTestScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    let show = ShowController()
    let controller = IpadTimelinePlaybackController()
    var rebuilds = 0
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        let window = UIWindow(windowScene: scene as! UIWindowScene); self.window = window
        window.rootViewController = controller; window.makeKeyAndVisible()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.run() }
    }
    func configure(_ viewport: IpadTimelineViewport, _ drawing: IpadTimelineRenderWindow) {
        rebuilds += 1
        controller.configure(show: show, viewport: viewport, window: drawing, size: CGSize(width: 800, height: 500),
            gridTop: 80, timeHeight: 16, follow: true, colors: [0xff0000, 0xffff00, 0x00ff00],
            rebase: { _ in }, scrollingChanged: { _ in },
            content: AnyView(Color.gray.frame(width: 1600, height: 500)))
    }
    private var resultURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("result.txt") }
    private func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { try? ("FAILED: " + message).write(to: resultURL, atomically: true, encoding: .utf8); exit(1) }
    }
    func run() {
        let viewport = IpadTimelineViewport(start: 100, span: 60)
        configure(viewport, IpadTimelineRenderWindow(viewport))
        let host = controller.hostingViewForTest
        // Move past any initial display frame consumed while UIKit mounted.
        show.snapshot.transport.position = 140
        controller.frameForTest(elapsed: 0)
        let offset = controller.scrollOffsetForTest
        controller.frameForTest(elapsed: 1.0 / 60)
        require(controller.scrollOffsetForTest > offset, "Continuous scroll advances between transport publications")
        require(abs(controller.needleXForTest - 400) < 0.01, "Playhead stays centered while content translates")
        require(controller.hostingViewForTest === host && rebuilds == 1, "Display frames preserve the drawn item tree")
        require(controller.hasClockForTest && controller.preferredCadenceForTest == 60, "Active playback uses the screen clock")
        let before = controller.visibleStart
        configure(viewport, IpadTimelineRenderWindow(.init(start: before, span: 60)))
        require(controller.visibleStart >= before - 0.00001, "Rebasing cannot move the viewport back to an old input anchor")
        controller.frameForTest(elapsed: 1.0 / 60)
        require(abs(controller.needleXForTest - 400) < 0.01, "Rebased content and cursor retain identical projection")
        show.timelineFollowPaused = true
        let frozen = controller.visibleStart
        show.snapshot.transport.position = 145
        controller.frameForTest(elapsed: 1.0 / 60)
        require(controller.visibleStart == frozen, "Manual navigation immediately suspends following")
        require(controller.needleXForTest > 400, "Needle continues while following is paused")
        show.timelineFollowPaused = false
        show.snapshot.transport.subPlay = SubPlayState(playing: true, position: 120)
        controller.frameForTest(elapsed: 0)
        require(abs(controller.visibleStart - 90) < 0.01, "Subplay takes follow priority even to the left of the previous midpoint")
        show.snapshot.transport.subPlay.playing = false
        show.snapshot.transport.position = 145
        controller.frameForTest(elapsed: 0)
        require(abs(controller.visibleStart - 115) < 0.01, "Cancelling Subplay returns to the running main head")
        show.snapshot.transport.playing = false
        controller.frameForTest(elapsed: 0.02)
        require(!controller.hasClockForTest && controller.mainHiddenForTest, "Stop disables the display clock and running needle")
        controller.stop()
        try? "IPAD_PLAYBACK_RETAINED_CONTENT_DISPLAY_CLOCK_STOP_SUBPLAY_AND_MANUAL_NAVIGATION_OK".write(to: resultURL, atomically: true, encoding: .utf8)
        print("IPAD_PLAYBACK_RETAINED_CONTENT_DISPLAY_CLOCK_STOP_SUBPLAY_AND_MANUAL_NAVIGATION_OK")
        fflush(stdout)
        exit(0)
    }
}
