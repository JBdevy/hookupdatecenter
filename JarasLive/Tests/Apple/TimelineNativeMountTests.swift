// The real mount and slot are extracted from TimelineGridView.swift. Only the
// controller's drawing/input children are substituted: this exercises SwiftUI's
// AppKit size negotiation, including the retained fitting-size shrink regression.
@MainActor private final class NativeTimelineBaseController {
    var mounts: [NativeTimelineBaseMountView.Kind: NativeTimelineBaseMountView] = [:]
    func makeMount(_ kind: NativeTimelineBaseMountView.Kind) -> NativeTimelineBaseMountView {
        let mount = NativeTimelineBaseMountView()
        mount.controller = self
        let head = MountInputProbe(frame: CGRect(x: 0, y: 0, width: 200, height: 71))
        let body = MountInputProbe(frame: CGRect(x: 20, y: 300, width: 200, height: 40))
        mount.addSubview(head); mount.addSubview(body)
        mounts[kind] = mount
        return mount
    }
    func observeScroll() {}
    func detachIfUnused() {}
}
private final class MountInputProbe: NSView {
    var clicks = 0
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { clicks += 1 }
}
private final class MountFixtureState: ObservableObject {
    @Published var size = CGSize(width: 900, height: 1600)
}
private struct NativeMountFixture: View {
    @ObservedObject var state: MountFixtureState
    let controller: NativeTimelineBaseController
    let nested: Bool
    private var planes: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: state.size.width, height: state.size.height)
            if nested {
                NativeTimelinePinnedLayer(width: state.size.width, height: state.size.height, content:
                    NativeTimelineBaseSlot(controller: controller, kind: .ruler)
                        .frame(width: state.size.width, height: state.size.height, alignment: .topLeading)
                ).frame(width: state.size.width, height: state.size.height)
            } else {
                NativeTimelineBaseSlot(controller: controller, kind: .ruler)
                    .frame(width: state.size.width, height: state.size.height, alignment: .topLeading)
            }
        }
        .frame(width: state.size.width, height: state.size.height, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            NativeTimelineBaseSlot(controller: controller, kind: .foreground)
                .frame(width: state.size.width, height: state.size.height, alignment: .topLeading)
        }
        .background {
            NativeTimelineBaseSlot(controller: controller, kind: .background)
                .frame(width: state.size.width, height: state.size.height, alignment: .topLeading)
        }
    }
    var body: some View {
        if nested {
            GridScrollView(axis: .vertical, contentWidth: 600, contentHeight: state.size.height) {
                GridScrollView(axis: .horizontal, contentWidth: state.size.width, contentHeight: state.size.height) {
                    planes
                }.frame(width: 600, height: state.size.height)
            }.frame(width: 600, height: 600)
        } else {
            planes.frame(width: 1400, height: 2600, alignment: .topLeading)
        }
    }
}
@MainActor private func verifyStructuralNativeMounts(nested: Bool) {
    let state = MountFixtureState(), controller = NativeTimelineBaseController()
    let window = NSWindow(contentRect: CGRect(x: -10000, y: -10000, width: nested ? 600 : 1400,
                                              height: nested ? 600 : 2600),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let root = NSHostingView(rootView: NativeMountFixture(state: state, controller: controller, nested: nested))
    window.contentView = root
    func settle() {
        for _ in 0..<3 {
            root.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
    }
    settle()
    let originalMounts = controller.mounts
    precondition(originalMounts.count == 3)
    let scrolls = allDescendants(GridNativeScrollView.self, in: root)
    if nested {
        precondition(scrolls.count == 2)
        scrolls[0].contentView.scroll(to: CGPoint(x: 0, y: 240))
        scrolls[1].contentView.scroll(to: CGPoint(x: 180, y: 0))
    }
    // Deleting regions/contents reduces lanes and document height. Undo can
    // grow them again; a second delete must not retain either former minimum.
    for size in [CGSize(width: 900, height: 1600), CGSize(width: 1200, height: 2400),
                 CGSize(width: 700, height: 1200), CGSize(width: 1300, height: 2200),
                 CGSize(width: 650, height: 900), CGSize(width: 900, height: 1600)] {
        state.size = size; settle()
        for (kind, mount) in controller.mounts {
            precondition(mount === originalMounts[kind], "structural edits retain the native controller mounts")
            precondition(mount.frame.size == size, "each mount accepts the new document extent, including shrink: \(kind) \(mount.frame.size) vs \(size)")
            let origin: CGPoint
            if nested {
                origin = mount.convert(.zero, to: scrolls[1].documentView!)
                let expectedY = kind == .ruler ? scrolls[0].contentView.bounds.minY : 0
                precondition(abs(origin.x) < 0.01 && abs(origin.y - expectedY) < 0.01,
                             "header remains pinned and body/input planes remain aligned after a structural edit: \(kind) \(origin) expectedY \(expectedY)")
            } else {
                origin = mount.convert(.zero, to: root)
                precondition(abs(origin.x) < 0.01 && abs(origin.y) < 0.01,
                             "the native plane never centers an obsolete fitting size inside a smaller document")
            }
            let head = mount.subviews[0] as! MountInputProbe
            let body = mount.subviews[1] as! MountInputProbe
            precondition(head.frame.minY == 0 && body.frame.minY == 300,
                         "native ruler and fill children retain document coordinates")
            let point = mount.convert(CGPoint(x: 30, y: 20), to: mount.superview!)
            precondition(mount.hitTest(point) === head, "header input remains aligned with its visible head after shrink")
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: head.convert(CGPoint(x: 30, y: 20), to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            let before = head.clicks
            mount.hitTest(point)?.mouseDown(with: event)
            precondition(head.clicks == before + 1, "retained header targets keep their original event routing")
        }
    }
    window.close()
}
MainActor.assumeIsolated {
    verifyStructuralNativeMounts(nested: false)
    verifyStructuralNativeMounts(nested: true)
}
print("NATIVE_TIMELINE_MOUNTS_SHRINK_GROW_ORIGIN_PINNING_INPUT_AND_REUSE_OK")
