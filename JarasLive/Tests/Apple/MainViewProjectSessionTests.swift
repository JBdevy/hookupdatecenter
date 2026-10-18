import SwiftUI
import AppKit

@MainActor final class FixtureShow {
    var projectSessionID = UUID()
    var toggleTracksPanel: () -> Void = {}
    var toggleSetlistPanel: () -> Void = {}
    var togglePartsPanel: () -> Void = {}
}
@MainActor final class WorkspaceSession: ObservableObject {
    @Published var opened = UUID()
    let show = FixtureShow()
    func replace() { show.projectSessionID = UUID(); opened = UUID() }
}
@MainActor enum DAWRemoteHostBridge { static func bind(_ show: FixtureShow) {} }
@MainActor final class ResolumeController {
    static let shared = ResolumeController()
    func bind(_ show: FixtureShow) {}
    func stop() {}
}
@MainActor final class MappingFixture { func bind(_ show: FixtureShow) {} }
@MainActor final class FXWindows {
    static let shared = FXWindows()
    var closes = 0
    func closeAll() { closes += 1 }
}
@MainActor final class DetachedMixerFixture: ObservableObject {
    static var closes = 0
    func close() { Self.closes += 1 }
}
@MainActor final class DetachedSetlistFixture: ObservableObject {
    static var closes = 0
    func close() { Self.closes += 1 }
}
@MainActor final class RightClickRouter {
    static let shared = RightClickRouter()
    var interactionBlocked = true
}
@MainActor enum SidebarWidthLimits { static let trackMixer = 280.0, setlist = 300.0 }
@MainActor enum PanelInvocation { static var count = 0 }
@MainActor struct WorkspaceFixture: View {
    let show: FixtureShow
    let remotePresentation = false
    let mappings = MappingFixture()
    @State private var presentedSessionID: UUID?
    @State private var mixerWidth = 280.0
    @State private var mixerRestoreWidth = 280.0
    @State private var setlistWidth = 300.0
    @State private var setlistRestoreWidth = 300.0
    @StateObject private var detachedMixer = DetachedMixerFixture()
    @StateObject private var detachedSetlist = DetachedSetlistFixture()
    @State private var partsRightOpen = false
    private func toggleMixer() { Self.togglePanel(width: $mixerWidth, restore: $mixerRestoreWidth, minimum: SidebarWidthLimits.trackMixer) }
    private func toggleSetlist() { Self.togglePanel(width: $setlistWidth, restore: $setlistRestoreWidth, minimum: SidebarWidthLimits.setlist) }
    static func togglePanel(width: Binding<Double>, restore: Binding<Double>, minimum: Double) {
        PanelInvocation.count += 1
        width.wrappedValue = width.wrappedValue > 0 ? 0 : max(minimum, restore.wrappedValue)
    }
    var body: some View {
        Text("Session lifecycle regression fixture").frame(width: 200, height: 120)
            .onAppear {
                // INSERT_APPEAR
            }
            .onDisappear {
                // INSERT_DISAPPEAR
            }
    }
}
@MainActor struct FixtureRoot: View {
    @ObservedObject var session: WorkspaceSession
    var body: some View { WorkspaceFixture(show: session.show).id(session.opened) }
}
@MainActor func settle() {
    let until = Date(timeIntervalSinceNow: 0.12)
    while Date() < until { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005)) }
}
@MainActor func run() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let session = WorkspaceSession()
    let view = NSHostingView(rootView: FixtureRoot(session: session))
    let window = NSWindow(contentRect: NSRect(x: 10,y: 10,width: 200,height: 120), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = view; window.orderFront(nil); settle()
    var failures = 0
    func check(_ condition: Bool, _ message: String) {
        if !condition { failures += 1; fputs("FAIL: \(message)\n", stderr) }
    }
    for iteration in 0..<12 {
        if iteration > 0 { session.replace(); settle() }
        let before = PanelInvocation.count
        session.show.toggleTracksPanel(); session.show.toggleSetlistPanel(); settle()
        check(PanelInvocation.count == before + 2,
              "Replacement workspace \(iteration) must retain both panel actions after the previous workspace disappears")
        check(FXWindows.shared.closes == 0,
              "Previous workspace must not close editors owned by the new session")
        check(RightClickRouter.shared.interactionBlocked,
              "Previous workspace must not change the new session's interaction gate")
    }
    check(DetachedMixerFixture.closes == 11, "Every outgoing workspace must still close its own detached mixer")
    check(DetachedSetlistFixture.closes == 11, "Every outgoing workspace must close its own detached Setlist")
    window.orderOut(nil)
    if failures == 0 { print("MAIN_VIEW_SESSION_REPLACEMENT_RETAINS_CURRENT_CALLBACKS_AND_EDITORS_OK") }
    exit(failures == 0 ? 0 : 1)
}
Task { @MainActor in run() }
dispatchMain()
