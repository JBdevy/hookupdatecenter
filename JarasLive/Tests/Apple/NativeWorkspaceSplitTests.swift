import SwiftUI
import AppKit

private let editRequest = TrackDetailsEditRequest(project: UUID(), tracks: [UUID(), UUID()], name: "Track", color: 0x123456, nameEditable: false)
@MainActor private final class WorkspaceTestState: ObservableObject {
    @Published var width: CGFloat = 320
    @Published var revision = 0
    var restore: CGFloat = 320
    var commits: [CGFloat] = []
    var actions: [String] = []
    var rootEvaluations = 0
    let scroll = SidebarScrollController()
    func toggle() {
        if width > 0 { restore = width; width = 0 } else { width = restore }
    }
}
private final class WorkspaceControl: NSView {
    var role = ""
    var count = 0
    var revision = 0
    var blocked = false
    var language = ""
    var dark = false
    var increment: () -> Void = {}
    var actions: () -> Void = {}
    override var acceptsFirstResponder: Bool { true }
}
private struct ControlProbe: NSViewRepresentable {
    let role: String, count: Int, revision: Int
    let increment: () -> Void
    let actions: () -> Void
    @Environment(\.gridInteractionBlocked) private var blocked
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var scheme
    func makeNSView(context: Context) -> WorkspaceControl { WorkspaceControl() }
    func updateNSView(_ view: WorkspaceControl, context: Context) {
        view.role = role; view.count = count; view.revision = revision
        view.increment = increment; view.actions = actions
        view.blocked = blocked; view.language = locale.identifier; view.dark = scheme == .dark
    }
}
private struct StatefulControl: View {
    let role: String, revision: Int
    @State private var count = 0
    @Environment(\.openFX) private var fx
    @Environment(\.openClipFXChain) private var clipFX
    @Environment(\.editTextItem) private var text
    @Environment(\.editTrackDetails) private var details
    var body: some View {
        ControlProbe(role: role, count: count, revision: revision, increment: { count += 1 }, actions: {
            fx(nil, "eq"); clipFX(editRequest.project); text(editRequest.project); details(editRequest)
        })
    }
}
private struct LeadingPane: View {
    let revision: Int
    var body: some View {
        GeometryReader { geometry in
            GridScrollView(axis: .vertical, contentWidth: geometry.size.width, contentHeight: 2400) {
                VStack(spacing: 0) {
                    StatefulControl(role: "left", revision: revision).frame(height: 40)
                    GridScrollView(axis: .horizontal, contentWidth: 4000, contentHeight: 2360) {
                        Color.blue.frame(width: 4000, height: 2360)
                    }.frame(width: geometry.size.width, height: 2360)
                }.frame(width: geometry.size.width, height: 2400)
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
private struct TrailingPane: View {
    let revision: Int
    let controller: SidebarScrollController
    var body: some View {
        VStack(spacing: 0) {
            StatefulControl(role: "right", revision: revision).frame(height: 40)
            ScrollViewReader { _ in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(0..<100) { row in Text("Song \(row)").lineLimit(1).frame(height: 40) }
                    }.frame(maxWidth: .infinity).background(SidebarScrollProbe(controller: controller))
                }
            }
        }
    }
}
private struct WorkspaceFixture: View {
    @ObservedObject var state: WorkspaceTestState
    var body: some View {
        let _ = { state.rootEvaluations += 1 }()
        let revision = state.revision
        VStack(spacing: 0) {
            Text("Transport").frame(height: 60)
            GeometryReader { geometry in
                NativeWorkspaceSplit(width: state.width, restoreWidth: state.restore, minimum: 277,
                    scrollController: state.scroll, onToggle: state.toggle, onEnd: { width in
                        state.width = width; state.restore = width; state.commits.append(width)
                    }) {
                    LeadingPane(revision: revision).foregroundStyle(.white)
                } trailing: {
                    TrailingPane(revision: revision, controller: state.scroll).foregroundStyle(.white)
                }.frame(width: geometry.size.width, height: geometry.size.height)
            }
            Text("Footer").frame(height: 30)
        }
        .environment(\.locale, Locale(identifier: revision == 0 ? "en" : "pt_BR"))
        .environment(\.colorScheme, revision == 0 ? .dark : .light)
        .environment(\.gridInteractionBlocked, revision % 2 == 1)
        .environment(\.openFX, { _, _ in state.actions.append("fx\(revision)") })
        .environment(\.openClipFXChain, { _ in state.actions.append("clip\(revision)") })
        .environment(\.editTextItem, { _ in state.actions.append("text\(revision)") })
        .environment(\.editTrackDetails, { request in
            precondition(request.project == editRequest.project && request.tracks == editRequest.tracks && !request.nameEditable)
            state.actions.append("details\(revision)")
        })
    }
}
private final class WorkspaceRoot: NSHostingView<WorkspaceFixture> {
    var layouts = 0
    override func layout() { layouts += 1; super.layout() }
}
private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
}
private func settle(_ view: NSView) {
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    view.layoutSubtreeIfNeeded()
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    let state = WorkspaceTestState()
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let root = WorkspaceRoot(rootView: WorkspaceFixture(state: state))
    window.contentView = root; settle(root)
    let divider = descendants(MixerDividerView.self, in: root).first!
    let leftHost = descendants(NSView.self, in: root).first { $0.identifier?.rawValue == "workspace-timeline" }!
    let rightHost = descendants(NSView.self, in: root).first { $0.identifier?.rawValue == "workspace-setlist" }!
    let controls = descendants(WorkspaceControl.self, in: root)
    precondition(controls.count == 2)
    let leftControl = controls.first { $0.role == "left" }!, rightControl = controls.first { $0.role == "right" }!
    precondition(leftHost is SidebarResizeLayoutBoundary && rightHost is SidebarResizeLayoutBoundary)
    for control in controls {
        precondition(control.language == "en" && control.dark && !control.blocked)
        control.increment(); control.actions()
    }
    settle(root)
    precondition(controls.allSatisfy { $0.count == 1 })
    precondition(state.actions == ["fx0", "clip0", "text0", "details0", "fx0", "clip0", "text0", "details0"])
    precondition(window.makeFirstResponder(rightControl))
    let focused = window.firstResponder
    let grids = descendants(GridNativeScrollView.self, in: leftHost)
    grids[0].contentView.scroll(to: CGPoint(x: 0, y: 160))
    grids[1].contentView.scroll(to: CGPoint(x: 500, y: 0))
    let initialX = divider.convert(CGPoint(x: 7, y: 50), to: nil).x
    let eventY = divider.convert(CGPoint(x: 7, y: 50), to: nil).y
    func event(_ type: NSEvent.EventType, delta: CGFloat, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: initialX + delta, y: eventY), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }
    let evaluations = state.rootEvaluations, rootLayouts = root.layouts
    divider.mouseDown(with: event(.leftMouseDown, delta: 0))
    var timings: [Double] = []
    for delta: CGFloat in [-4, -18, -80, -130, -30, 15, -90] {
        let start = CFAbsoluteTimeGetCurrent()
        divider.mouseDragged(with: event(.leftMouseDragged, delta: delta))
        timings.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        let width = min(486.5, max(277, 320 - delta))
        precondition(abs(rightHost.frame.width - width) < 0.01 && abs(leftHost.frame.width - (1200 - width - 14)) < 0.01)
        precondition(abs(divider.convert(CGPoint(x: 7, y: 50), to: nil).x - (initialX + 320 - width)) < 0.01,
                     "native sibling frames follow the pointer exactly before mouseDragged returns")
        precondition(state.rootEvaluations == evaluations && root.layouts == rootLayouts,
                     "horizontal drag never evaluates or lays out the transport/footer host")
        precondition(state.width == 320 && state.commits.isEmpty)
        precondition(window.firstResponder === focused && controls.allSatisfy { $0.count == 1 })
        precondition(abs(grids[0].contentView.bounds.minY - 160) < 0.01 && abs(grids[1].contentView.bounds.minX - 500) < 0.01)
    }
    let liveWidth = rightHost.frame.width
    state.revision = 1; settle(root)
    precondition(rightHost.frame.width == liveWidth, "an unrelated parent update carrying the old saved width cannot override the drag")
    for control in controls {
        precondition(control.revision == 1 && control.language == "pt_BR" && !control.dark && control.blocked)
        control.actions()
    }
    precondition(Array(state.actions.suffix(8)) == ["fx1", "clip1", "text1", "details1", "fx1", "clip1", "text1", "details1"])
    divider.mouseUp(with: event(.leftMouseUp, delta: -45))
    precondition(state.width == 365 && state.commits == [365] && rightHost.frame.width == 365)
    settle(root)
    precondition(rightHost.frame.width == 365 && controls.allSatisfy { $0.count == 1 })
    precondition(descendants(WorkspaceControl.self, in: root).contains { $0 === leftControl })
    precondition(descendants(WorkspaceControl.self, in: root).contains { $0 === rightControl })

    state.width = 0; settle(root)
    precondition(rightHost.isHidden && leftHost.frame.width == 1186)
    state.toggle(); settle(root)
    precondition(!rightHost.isHidden && rightHost.frame.width == 365 && rightControl.count == 1)
    divider.mouseDown(with: event(.leftMouseDown, delta: 0, clicks: 2)); settle(root)
    precondition(rightHost.isHidden && state.width == 0, "double click still toggles the native panel")
    divider.mouseDown(with: event(.leftMouseDown, delta: 0))
    divider.mouseUp(with: event(.leftMouseUp, delta: 0)); settle(root)
    precondition(!rightHost.isHidden && state.width == 365 && rightControl.count == 1,
                 "clicking the collapsed divider restores the same mounted content")
    window.setContentSize(CGSize(width: 620, height: 760)); settle(root)
    precondition(rightHost.frame.width == 200 && leftHost.frame.width == 406 && divider.frame.height == 670)
    window.setContentSize(CGSize(width: 1200, height: 700)); settle(root)
    precondition(rightHost.frame.width == 365 && state.width == 365)

    // The original native vertical scrollbar still targets the setlist scroll.
    precondition(state.scroll.metrics.canScroll)
    let oldOffset = state.scroll.metrics.offset
    let down = divider.convert(CGPoint(x: 7, y: 50), to: nil)
    func vertical(_ type: NSEvent.EventType, y: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: down.x, y: down.y - y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    divider.mouseDown(with: vertical(.leftMouseDown, y: 0))
    divider.mouseDragged(with: vertical(.leftMouseDragged, y: 50))
    divider.mouseUp(with: vertical(.leftMouseUp, y: 50))
    precondition(state.scroll.metrics.offset > oldOffset && state.commits == [365])

    // A child mixer divider commits only its nearest workspace host.
    let embedded = MixerDividerView(frame: CGRect(x: 20, y: 50, width: 20, height: 200))
    leftHost.addSubview(embedded)
    embedded.columnWidth = 300; embedded.minimum = 277; embedded.maximum = 486.5
    let layoutCount = root.layouts
    embedded.onResize = { _ in leftHost.needsLayout = true }
    let point = embedded.convert(CGPoint(x: 10, y: 50), to: nil)
    func inner(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: point.x + x, y: point.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    embedded.mouseDown(with: inner(.leftMouseDown, x: 0)); embedded.mouseDragged(with: inner(.leftMouseDragged, x: 20)); embedded.mouseUp(with: inner(.leftMouseUp, x: 20))
    precondition(root.layouts == layoutCount, "mixer commits stop at the workspace boundary rather than the app root")
    embedded.removeFromSuperview()
    let beforeDetach = state.commits
    divider.mouseDown(with: event(.leftMouseDown, delta: 0))
    divider.mouseDragged(with: event(.leftMouseDragged, delta: -20))
    window.contentView = nil
    divider.mouseUp(with: event(.leftMouseUp, delta: -80))
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    precondition(state.commits == beforeDetach, "detaching the workspace never saves or replays an abandoned drag")
    print("WORKSPACE_NATIVE_SPLIT_GEOMETRY_ENVIRONMENT_STATE_FOCUS_SCROLL_COLLAPSE_AND_LAYOUT_BOUNDARY_OK mean_ms=\(timings.reduce(0,+)/Double(timings.count))")
    window.close()
}
