import AppKit
import SwiftUI

@MainActor private final class NativeTimelineBaseController: ObservableObject {
    static var constructions = 0
    init() { Self.constructions += 1 }
}
private final class OwnerProbeView: NSView { var identity: ObjectIdentifier?; var revision = 0 }
private struct OwnerProbe: NSViewRepresentable {
    let owner: NativeTimelineBaseController
    let revision: Int
    func makeNSView(context: Context) -> OwnerProbeView { OwnerProbeView() }
    func updateNSView(_ view: OwnerProbeView, context: Context) {
        view.identity = ObjectIdentifier(owner); view.revision = revision
    }
}
private struct OwnerFixture: View {
    let revision: Int
    // PRODUCTION_NATIVE_OWNER_STORAGE
    var body: some View { OwnerProbe(owner: nativeBase, revision: revision).frame(maxWidth: .infinity, maxHeight: .infinity) }
}
private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
}
private func settle(_ view: NSView) {
    view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.01)); view.layoutSubtreeIfNeeded()
}
MainActor.assumeIsolated {
    _ = NSApplication.shared
    let root = NSHostingView(rootView: OwnerFixture(revision: 0))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 500),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = root; settle(root)
    let probe = descendants(OwnerProbeView.self, in: root).first!
    let firstIdentity = probe.identity
    precondition(NativeTimelineBaseController.constructions == 1)
    for revision in 1...24 {
        root.rootView = OwnerFixture(revision: revision)
        window.setContentSize(NSSize(width: 900 - revision * 7, height: 500)); settle(root)
        precondition(probe.revision == revision && probe.identity == firstIdentity,
                     "Existing native controller and live model updates must survive parent rebuilding")
        precondition(NativeTimelineBaseController.constructions == 1,
                     "Reevaluating a timeline must not construct discarded native/Metal controllers")
    }
    let anotherRoot = NSHostingView(rootView: OwnerFixture(revision: 99))
    window.contentView = anotherRoot; settle(anotherRoot)
    precondition(NativeTimelineBaseController.constructions == 2,
                 "A different mounted timeline needs its own native controller")
    precondition(descendants(OwnerProbeView.self, in: anotherRoot).first?.identity != firstIdentity)
    window.close()
    print("TIMELINE_NATIVE_OWNER_FACTORY_RUNS_ONCE_PER_MOUNT_ACROSS_PARENT_AND_VIEWPORT_UPDATES_OK")
}
