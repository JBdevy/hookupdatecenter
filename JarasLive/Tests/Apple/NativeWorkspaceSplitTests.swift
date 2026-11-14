import SwiftUI
import AppKit

// The selection adapter is not mounted by this layout/focus fixture.
struct GridSelectionInput { func apply(to view: GridSelectionView) {} }
final class GridSelectionView: NSView {}

enum WorkspaceRootUpdateProbe { static var count = 0 }
enum WorkspaceMixerLayoutProbe { static var count = 0 }
enum WorkspaceGeometryIdentityProbe { static var tokens: [UUID] = [] }
enum WorkspaceGeometryFinalLayoutProbe { static var commit: (() -> Void)? }

private let editRequest = TrackDetailsEditRequest(project: UUID(), tracks: [UUID(), UUID()], name: "Track", color: 0x123456, nameEditable: false)
@MainActor private final class WorkspaceTestState: ObservableObject {
    @Published var width: CGFloat = 320
    @Published var revision = 0
    @Published var pulse = 0
    @Published var sidebarLeading = false
    @Published var sidebarDetached = false
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
                    scrollController: state.scroll, sidebarLeading: state.sidebarLeading, sidebarDetached: state.sidebarDetached, contentIdentity: state.revision, onToggle: state.toggle, onEnd: { width in
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
    let updatesBefore = WorkspaceRootUpdateProbe.count
    for _ in 0..<10 { state.pulse += 1; settle(root) }
    precondition(WorkspaceRootUpdateProbe.count == updatesBefore,
                 "unrelated parent publications must not replace grid/setlist hosting roots")
    precondition(controls.allSatisfy { $0.count == 1 }, "child control state survives stable root publications")
    print("WORKSPACE_PARENT_PUBLICATIONS_PRESERVE_NATIVE_ROOTS_AND_CHILD_CONTROL_STATE_OK")

    let originalWindowSize = window.contentView!.frame.size
    let originalHostedHeight = leftHost.frame.height
    NotificationCenter.default.post(name: Notification.Name("CatLiveFooterResizeBegan"), object: window)
    for reduction: CGFloat in [20, 60, 110, 40] {
        window.setContentSize(NSSize(width: originalWindowSize.width, height: originalWindowSize.height - reduction)); settle(root)
        precondition(leftHost.frame.height == originalHostedHeight && rightHost.frame.height == originalHostedHeight,
                     "Footer expansion must crop the workspace without remeasuring timeline/Setlist rows")
        precondition(leftHost.superview!.layer?.masksToBounds == true, "Cropped workspace must not draw over the footer")
    }
    NotificationCenter.default.post(name: Notification.Name("CatLiveFooterResizeEnded"), object: window); settle(root)
    precondition(leftHost.frame.height == leftHost.superview!.bounds.height && rightHost.frame.height == leftHost.frame.height,
                 "Releasing or cancelling footer resize must restore the exact workspace viewport")
    window.setContentSize(originalWindowSize); settle(root)
    print("WORKSPACE_FOOTER_RESIZE_RETAINS_HOST_LAYOUT_AND_FINAL_VIEWPORT_OK")

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
    let evaluations = state.rootEvaluations
    divider.mouseDown(with: event(.leftMouseDown, delta: 0))
    var timings: [Double] = []
    for delta: CGFloat in [-4, -18, -80, -130, -30, 15, -90] {
        let start = CFAbsoluteTimeGetCurrent()
        divider.mouseDragged(with: event(.leftMouseDragged, delta: delta))
        RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        timings.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        let width = min(486.5, max(277, 320 - delta))
        precondition(abs(rightHost.frame.width - width) < 0.01 && abs(leftHost.frame.width - (1200 - width - divider.frame.width)) < 0.01)
        precondition(abs(divider.convert(CGPoint(x: 7, y: 50), to: nil).x - (initialX + 320 - width)) < 0.01,
                     "native sibling frames follow the pointer exactly before mouseDragged returns")
        precondition(state.rootEvaluations == evaluations,
                     "horizontal drag never reevaluates the transport/footer content")
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
    precondition(rightHost.isHidden && leftHost.frame.width == 1200 - divider.frame.width)
    state.toggle(); settle(root)
    precondition(!rightHost.isHidden && rightHost.frame.width == 365 && rightControl.count == 1)
    divider.mouseDown(with: event(.leftMouseDown, delta: 0, clicks: 2)); settle(root)
    precondition(rightHost.isHidden && state.width == 0, "double click still toggles the native panel")
    divider.mouseDown(with: event(.leftMouseDown, delta: 0))
    divider.mouseUp(with: event(.leftMouseUp, delta: 0)); settle(root)
    precondition(!rightHost.isHidden && state.width == 365 && rightControl.count == 1,
                 "clicking the collapsed divider restores the same mounted content")
    window.setContentSize(CGSize(width: 620, height: 760)); settle(root)
    precondition(rightHost.frame.width == 200 && leftHost.frame.width == 420 - divider.frame.width && divider.frame.height == 670)
    window.setContentSize(CGSize(width: 1200, height: 700)); settle(root)
    precondition(rightHost.frame.width == 365 && state.width == 365)

    // Keyboard scroll uses the same paired vertical clip, independently of the
    // mouse location. Horizontal arrows affect only the nested timeline clip.
    let keyboardScroll = SidebarScrollController()
    keyboardScroll.attach(grids[0], owner: leftHost)
    grids[1].logicalDocumentWidth = 4000
    let beforeY = grids[0].contentView.bounds.minY
    let beforeX = grids[1].contentView.bounds.minX
    precondition(keyboardScroll.scrollTimelineByArrow(125))
    precondition(grids[0].contentView.bounds.minY == beforeY + 72 && grids[1].contentView.bounds.minX == beforeX)
    precondition(keyboardScroll.scrollTimelineByArrow(126))
    precondition(grids[0].contentView.bounds.minY == beforeY)
    precondition(keyboardScroll.scrollTimelineByArrow(124))
    precondition(grids[1].contentView.bounds.minX == beforeX + 72 && grids[0].contentView.bounds.minY == beforeY)
    precondition(keyboardScroll.scrollTimelineByArrow(123))
    precondition(grids[1].contentView.bounds.minX == beforeX && !grids[1].permitsPlaybackFollow)
    grids[0].contentView.scroll(to: .zero); grids[1].contentView.scroll(to: .zero)
    precondition(keyboardScroll.scrollTimelineByArrow(126) && keyboardScroll.scrollTimelineByArrow(123))
    precondition(grids[0].contentView.bounds.minY == 0 && grids[1].contentView.bounds.minX == 0)
    precondition(!keyboardScroll.scrollTimelineByArrow(0))
    keyboardScroll.detach(owner: leftHost)
    print("DESKTOP_KEYBOARD_SCROLL_PAIRED_VERTICAL_GRID_HORIZONTAL_BOUNDS_AND_PLAYBACK_FOLLOW_OK")

    // The original native vertical scrollbar still targets the setlist scroll.
    divider.showsScrollRail = true
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
    divider.showsScrollRail = false

    // A child mixer divider commits only its nearest workspace host.
    let embedded = MixerDividerView(frame: CGRect(x: 20, y: 50, width: 20, height: 200))
    leftHost.addSubview(embedded)
    embedded.columnWidth = 300; embedded.minimum = 277; embedded.maximum = 486.5
    let contentEvaluations = state.rootEvaluations
    embedded.onResize = { _ in leftHost.needsLayout = true }
    let point = embedded.convert(CGPoint(x: 10, y: 50), to: nil)
    func inner(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: point.x + x, y: point.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    embedded.mouseDown(with: inner(.leftMouseDown, x: 0)); embedded.mouseDragged(with: inner(.leftMouseDragged, x: 20)); embedded.mouseUp(with: inner(.leftMouseUp, x: 20))
    precondition(state.rootEvaluations == contentEvaluations, "mixer commits preserve unrelated transport/footer content")
    embedded.removeFromSuperview()

    // Moving Setlist to the left preserves its host/state and mirrors resize direction.
    state.sidebarLeading = true; settle(root)
    precondition(rightHost.frame.minX == 0 && rightHost.frame.width == 365 && leftHost.frame.minX == 365 + divider.frame.width)
    precondition(divider.frame.minX == 365 && divider.direction == 1)
    precondition(descendants(WorkspaceControl.self, in: root).contains { $0 === rightControl } && rightControl.count == 1)
    let leftDown = divider.convert(CGPoint(x: 7, y: 50), to: nil)
    func leftSide(_ type: NSEvent.EventType, delta: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: leftDown.x + delta, y: leftDown.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    divider.mouseDown(with: leftSide(.leftMouseDown, delta: 0))
    divider.mouseDragged(with: leftSide(.leftMouseDragged, delta: 35))
    RunLoop.main.run(until: Date().addingTimeInterval(0.025))
    precondition(rightHost.frame.width == 400 && leftHost.frame.minX == 400 + divider.frame.width && state.width == 365,
                 "left Setlist grows when the divider moves right without publishing during drag")
    divider.mouseUp(with: leftSide(.leftMouseUp, delta: 35)); settle(root)
    precondition(state.width == 400 && state.commits.last == 400)
    state.sidebarDetached = true; settle(root)
    precondition(rightHost.isHidden && divider.isHidden && leftHost.frame.minX == 0 && leftHost.frame.width == 1200,
                 "detached Setlist must release its whole dock and divider width")
    precondition(state.width == 400 && state.restore == 400, "detaching must preserve dock width")
    state.sidebarDetached = false; settle(root)
    precondition(!rightHost.isHidden && !divider.isHidden && rightHost.frame.width == 400 && rightHost.frame.minX == 0,
                 "docking restores the previous side and width")
    state.sidebarLeading = false; settle(root)
    precondition(rightHost.frame.maxX == 1200 && leftHost.frame.minX == 0 && divider.direction == -1)
    precondition(rightControl.count == 1 && leftControl.count == 1,
                 "placement changes must not remount either native host")
    print("WORKSPACE_SETLIST_LEFT_RESIZE_DETACH_AND_DOCK_PRESERVE_STATE_OK")

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

@MainActor private final class RowRootsState: ObservableObject {
    @Published var selection: Set<Int> = [0]
    @Published var order = Array(0..<20)
    @Published var width: CGFloat = 300
    @Published var rowHeight: CGFloat = 60
    @Published var metadata = Array(repeating: 0, count: 20)
    @Published var pinned: Set<Int> = []
    let project = UUID(), song = UUID()
    let tracks = (0..<20).map { _ in UUID() }
    var builds: [Int] = []
}
private struct RowRootsFixture: View {
    @ObservedObject var state: RowRootsState
    var followsContainerWidth = false
    var limitsWidthToViewport = false
    var limitsVisibilityToViewport = false
    var body: some View {
        NativeTimelineMixerRows(size: CGSize(width: state.width, height: state.rowHeight * 20), rows: state.order.enumerated().map { slot, track in
            NativeTimelineMixerRowSpec(id: slot, frame: CGRect(x: 0, y: CGFloat(slot) * state.rowHeight, width: state.width, height: state.rowHeight),
                version: TimelineMixerRowVersion(project: state.project, song: state.song, track: state.tracks[track],
                    metadata: state.metadata[track], index: track, showsFader: state.width >= 180,
                    height: state.rowHeight, audioHeight: state.rowHeight, envelopeHeight: 0,
                    selection: state.selection.contains(track) ? [state.tracks[track]] : [],
                    silenced: false, showsIcons: false, nextTrack: nil, groupDepth: 0, lastChild: false, directory: nil),
                retained: state.pinned.contains(track))
        }, followsContainerWidth: followsContainerWidth, limitsWidthToViewport: limitsWidthToViewport,
           limitsVisibilityToViewport: limitsVisibilityToViewport) { slot in
            let track = state.order[slot]
            let _ = { state.builds.append(track) }()
            StatefulControl(role: "row\(track)", revision: state.selection.contains(track) ? 1 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
MainActor.assumeIsolated {
    let state = RowRootsState()
    let root = NSHostingView(rootView: RowRootsFixture(state: state))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 1200), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = root; settle(root)
    let controls = descendants(WorkspaceControl.self, in: root)
    precondition(controls.count == 20)
    let retained = controls.first { $0.role == "row0" }!
    retained.increment(); settle(root); precondition(retained.count == 1)
    NativeSidebarResizeActivity.shared.begin(owner: root)
    state.builds.removeAll(); state.selection = [8]; settle(root)
    precondition(state.builds.sorted() == [0, 8], "selection only assigns the roots of the two affected tracks")
    precondition(retained.count == 1 && retained.revision == 0)
    precondition(controls.first { $0.role == "row8" }!.revision == 1)
    precondition(descendants(WorkspaceControl.self, in: root).allSatisfy { current in controls.contains { $0 === current } }, "selection retains every native control")
    state.builds.removeAll(); state.order.swapAt(1, 19); settle(root)
    precondition(state.builds.sorted() == [1, 19], "recycling changes only the two rebound row roots")
    precondition(descendants(WorkspaceControl.self, in: root).count == 20)
    print("TRACK_MIXER_ROW_ROOTS_SELECTION_UPDATES_ONLY_CHANGED_TRACKS_AND_RECYCLING_RETAINS_CONTROLS_OK")
    state.builds.removeAll(); state.metadata[12] += 1; settle(root)
    precondition(state.builds == [12], "editing one track must not rebuild unrelated retained rows")
    precondition(retained.count == 1 && descendants(WorkspaceControl.self, in: root).allSatisfy { current in controls.contains { $0 === current } },
                 "track metadata edits retain native control state and identities")
    print("TRACK_MIXER_METADATA_EDITS_REBUILD_ONLY_THE_CHANGED_TRACK_OK")
    state.builds.removeAll()
    for width: CGFloat in [315, 410, 230, 185, 300] {
        state.width = width; settle(root)
        precondition(state.builds.isEmpty, "changing pixel width must not replace the mixer rows or their control content")
        precondition(controls.allSatisfy { abs($0.frame.width - width) < 0.01 },
                     "retained row controls must still reflow to the exact proposed width")
        precondition(retained.count == 1, "resizing preserves local control state")
    }
    state.width = 179; settle(root)
    precondition(state.builds.count == 20, "crossing the fader-visibility boundary updates the row content")
    state.builds.removeAll(); state.width = 170; settle(root)
    precondition(state.builds.isEmpty && controls.allSatisfy { abs($0.frame.width - 170) < 0.01 })
    state.width = 180; settle(root)
    precondition(state.builds.count == 20 && retained.count == 1, "restoring faders preserves the existing row state")
    print("TRACK_MIXER_WIDTH_REFLOWS_RETAINED_CONTROLS_WITHOUT_REBUILDING_CONTENT_EXCEPT_VISIBILITY_BOUNDARY_OK")
    retained.increment()
    NativeSidebarResizeActivity.shared.end(owner: root); settle(root)
    precondition(retained.count == 2, "releasing the divider flushes local row state")
    print("TRACK_MIXER_ACTIVE_DIVIDER_PRESERVES_SELECTION_REBIND_CONTENT_GEOMETRY_AND_FINAL_STATE_OK")
    window.close()
}

MainActor.assumeIsolated {
    let state = RowRootsState()
    let root = NSHostingView(rootView: RowRootsFixture(state: state))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 1200),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = root; settle(root)
    let controls = descendants(WorkspaceControl.self, in: root)
    let first = controls.first { $0.role == "row0" }!
    first.increment(); settle(root)
    var prior = state.rowHeight
    for height: CGFloat in [61, 62, 63, 64, 80, 120, 240, 90, 64, 63, 56, 55, 40, 24, 55, 56, 64] {
        state.builds.removeAll(); state.rowHeight = height; settle(root)
        let changesControls = (height < 56) != (prior < 56) || (height < 64) != (prior < 64)
        precondition(state.builds.count == (changesControls ? 20 : 0),
                     "height pixels must retain row roots except at compact/minimal control boundaries")
        precondition(controls.allSatisfy { abs($0.frame.height - height) < 0.01 },
                     "retained controls must immediately occupy the real height, without scaling")
        precondition(descendants(WorkspaceControl.self, in: root).allSatisfy { current in controls.contains { current === $0 } })
        precondition(first.count == 1, "height changes must preserve live control state")
        prior = height
    }
    print("TRACK_MIXER_HEIGHT_REFLOWS_REAL_FRAMES_WITHOUT_ROOT_REBUILD_EXCEPT_CONTROL_BOUNDARIES_OK")
    window.close()
}

MainActor.assumeIsolated {
    let state = RowRootsState()
    let root = NSHostingView(rootView: RowRootsFixture(state: state, followsContainerWidth: true,
                                                     limitsWidthToViewport: true))
    root.frame = CGRect(x: 0, y: 0, width: 300, height: 1200)
    let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 180))
    scroll.documentView = root
    let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = scroll; settle(root)
    let controls = descendants(WorkspaceControl.self, in: root)
    let first = controls.first { $0.role == "row0" }!
    let last = controls.first { $0.role == "row19" }!
    first.increment(); settle(root)
    state.builds.removeAll()
    root.setFrameSize(CGSize(width: 420, height: 1200)); settle(root)
    precondition(abs(first.frame.width - 420) < 0.01,
                 "native sizing must reflow the visible row without publishing a new SwiftUI root")
    precondition(abs(last.frame.width - 300) < 0.01,
                 "a divider drag must leave offscreen warm rows out of the width layout pass")
    precondition(state.builds.isEmpty && first.count == 1 && state.width == 300)
    scroll.contentView.scroll(to: CGPoint(x: 0, y: 1020)); settle(root)
    precondition(abs(last.frame.width - 420) < 0.01,
                 "scrolling an existing row into view must update its width before displaying its controls")
    precondition(state.builds.isEmpty && descendants(WorkspaceControl.self, in: root).allSatisfy { view in
        controls.contains { $0 === view }
    }, "width and viewport changes must preserve every mounted control")
    root.rootView = RowRootsFixture(state: state, followsContainerWidth: true, limitsWidthToViewport: false)
    settle(root)
    precondition(controls.allSatisfy { abs($0.frame.width - 420) < 0.01 },
                 "ending the resize brings all retained row widths up to date")
    print("TRACK_MIXER_NATIVE_WIDTH_REFLOW_VISIBLE_ROWS_SCROLL_AND_RESIZE_COMMIT_RETAIN_CONTROLS_OK")
    window.close()
}

MainActor.assumeIsolated {
    let state = RowRootsState()
    let root = NSHostingView(rootView: RowRootsFixture(state: state, followsContainerWidth: true))
    root.frame = CGRect(x: 0, y: 0, width: 300, height: 1200)
    let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 300, height: 180))
    scroll.documentView = root
    let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = scroll; settle(root)
    let controls = descendants(WorkspaceControl.self, in: root)
    precondition(controls.count == 20)
    let first = controls.first { $0.role == "row0" }!, last = controls.first { $0.role == "row19" }!
    first.increment(); settle(root)
    root.rootView = RowRootsFixture(state: state, followsContainerWidth: true, limitsVisibilityToViewport: true)
    settle(root)
    precondition(!first.isHiddenOrHasHiddenAncestor && last.isHiddenOrHasHiddenAncestor)
    precondition(controls.allSatisfy { $0.window === window }, "offscreen controls must retain their window and state")
    for y: CGFloat in [1020, 0, 650, 120, 1020, 0] {
        scroll.contentView.scroll(to: CGPoint(x: 0, y: y)); settle(root)
        for control in controls where control.convert(control.bounds, to: scroll.contentView).intersects(scroll.contentView.bounds) {
            precondition(!control.isHiddenOrHasHiddenAncestor, "a large scroll jump must reveal every visible row")
        }
    }
    precondition(first.count == 1 && descendants(WorkspaceControl.self, in: root).allSatisfy { view in controls.contains { $0 === view } })
    precondition(window.makeFirstResponder(first))
    scroll.contentView.scroll(to: CGPoint(x: 0, y: 1020)); settle(root)
    precondition(window.firstResponder === first && !first.isHiddenOrHasHiddenAncestor,
                 "scrolling must preserve a focused offscreen control")
    window.makeFirstResponder(nil)
    scroll.contentView.scroll(to: .zero); settle(root)
    state.pinned = [19]; settle(root)
    precondition(!last.isHiddenOrHasHiddenAncestor, "a menu or active control keeps its offscreen row available")
    state.pinned = []; state.selection = [19]; state.metadata[19] += 1; settle(root)
    scroll.contentView.scroll(to: CGPoint(x: 0, y: 1020)); settle(root)
    precondition(!last.isHiddenOrHasHiddenAncestor && last.revision == 1, "hidden rows must display current model state when revealed")
    scroll.contentView.setFrameSize(CGSize(width: 300, height: 1200)); scroll.contentView.scroll(to: .zero); settle(root)
    precondition(controls.allSatisfy { !$0.isHiddenOrHasHiddenAncestor }, "growing the viewport reveals the retained rows")
    print("TRACK_MIXER_WARM_ROOTS_VIEWPORT_JUMPS_PINNING_MODEL_UPDATES_AND_RESIZE_PRESERVE_CONTROLS_OK")
    window.close()
}

@MainActor private final class MixerSiblingWidthState: ObservableObject {
    @Published var viewport: CGFloat = 1000
    @Published var revision = 0
    var actions: [String] = []
    let project = UUID()
}
private struct MixerSiblingWidthFixture: View {
    @ObservedObject var state: MixerSiblingWidthState
    var body: some View {
        let revision = state.revision
        GridScrollView(axis: .vertical, contentWidth: state.viewport, contentHeight: 1800) {
            NativeTimelineColumns(mixerWidth: 300, viewportWidth: state.viewport, height: 1800,
                                  dividerWidth: 6, project: state.project, mixerIdentity: revision) {
                VStack(spacing: 0) {
                    StatefulControl(role: "retained-column", revision: revision).frame(height: 40)
                    Color.blue
                }.frame(maxWidth: .infinity).frame(height: 1800)
            } divider: { Color.gray } timeline: { Color.green }
                .frame(width: state.viewport, height: 1800, alignment: .topLeading)
        }.frame(width: state.viewport, height: 600)
        .environment(\.locale, Locale(identifier: revision == 0 ? "en" : "pt_BR"))
        .environment(\.colorScheme, revision == 0 ? .dark : .light)
        .environment(\.openFX, { _, _ in state.actions.append("fx\(revision)") })
    }
}
MainActor.assumeIsolated {
    let state = MixerSiblingWidthState()
    let root = NSHostingView(rootView: MixerSiblingWidthFixture(state: state))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = root; settle(root)
    let mixer = descendants(NSView.self, in: root).first { $0.identifier?.rawValue == "columns-mixer" }!
    let control = descendants(WorkspaceControl.self, in: mixer).first!
    let scroll = descendants(GridNativeScrollView.self, in: root).first!
    NativeSidebarResizeActivity.shared.begin(owner: root)
    let baseline = WorkspaceMixerLayoutProbe.count
    for width: CGFloat in [960, 920, 880] {
        state.viewport = width; mixer.needsLayout = true; settle(root)
        precondition(WorkspaceMixerLayoutProbe.count == baseline,
                     "Setlist viewport changes must not lay out a geometrically unchanged mixer column")
    }
    scroll.contentView.scroll(to: CGPoint(x: 0, y: 160)); mixer.needsLayout = true; settle(root)
    let afterScroll = WorkspaceMixerLayoutProbe.count
    precondition(afterScroll > baseline, "scrolling changes the visible band and must update hosted mixer rows during resize")
    NativeSidebarResizeActivity.shared.contentDidChange(); mixer.needsLayout = true; settle(root)
    precondition(WorkspaceMixerLayoutProbe.count > afterScroll, "model publications must invalidate a retained column")
    state.revision = 1; settle(root)
    precondition(control.revision == 1 && control.language == "pt_BR" && !control.dark,
                 "root identity and environment updates must pass the column gate")
    control.actions(); precondition(state.actions == ["fx1"], "updated column actions must remain current")
    mixer.needsLayout = true; settle(root)
    let beforeRelease = WorkspaceMixerLayoutProbe.count
    NativeSidebarResizeActivity.shared.end(owner: root); settle(root)
    precondition(WorkspaceMixerLayoutProbe.count > beforeRelease, "release flushes deferred column layout")
    print("SETLIST_RESIZE_RETAINS_MIXER_COLUMN_WITH_SCROLL_MODEL_ENVIRONMENT_ACTIONS_AND_RELEASE_FLUSH_OK")
    window.close()
}

@MainActor private final class MixerWidthState: ObservableObject {
    @Published var width: CGFloat = 300
    var publications = 0
    var commits: [CGFloat] = []
    var modes: [Bool] = []
    var cancellations = 0
    let nativeWidth = NativeTimelineMixerWidth()
}

@MainActor private final class NativeViewportFixtureState: ObservableObject {
    @Published var revision = 0
    var evaluations = 0
    var actions: [String] = []
    let project = UUID()
}
private struct NativeViewportFixture: View {
    @ObservedObject var state: NativeViewportFixtureState
    var body: some View {
        let _ = { state.evaluations += 1 }()
        let revision = state.revision
        // Content intentionally carries the original width. Native proposals
        // and the scroll clip must supply subsequent widths without a model
        // publication or replacing this content with another width snapshot.
        GridScrollView(axis: .vertical, contentWidth: 1200, contentHeight: 1800) {
            NativeTimelineColumns(mixerWidth: 300, viewportWidth: 1200, height: 1800,
                                  dividerWidth: 6, project: state.project, mixerIdentity: revision) {
                StatefulControl(role: "viewport-mixer", revision: revision)
                    .frame(maxWidth: .infinity).frame(height: 1800)
            } divider: { Color.gray } timeline: {
                GridScrollView(axis: .horizontal, contentWidth: 4000, contentHeight: 1800) {
                    StatefulControl(role: "viewport-timeline", revision: revision)
                        .frame(width: 4000, height: 1800)
                }.frame(maxWidth: .infinity).frame(height: 1800)
            }.frame(maxWidth: .infinity).frame(height: 1800)
        }.frame(maxWidth: .infinity).frame(height: 600)
        .environment(\.locale, Locale(identifier: revision == 0 ? "en" : "pt_BR"))
        .environment(\.colorScheme, revision == 0 ? .dark : .light)
        .environment(\.gridInteractionBlocked, revision % 2 == 1)
        .environment(\.openFX, { _, _ in state.actions.append("fx\(revision)") })
    }
}
MainActor.assumeIsolated {
    let state = NativeViewportFixtureState()
    let root = NSHostingView(rootView: NativeViewportFixture(state: state))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 600),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = root; settle(root)
    let scrolls = descendants(GridNativeScrollView.self, in: root)
    let vertical = scrolls[0], horizontal = scrolls[1]
    let mixer = descendants(NSView.self, in: root).first { $0.identifier?.rawValue == "columns-mixer" }!
    let divider = descendants(NSView.self, in: root).first { $0.identifier?.rawValue == "columns-divider" }!
    let timeline = descendants(NSView.self, in: root).first { $0.identifier?.rawValue == "columns-timeline" }!
    let control = descendants(WorkspaceControl.self, in: timeline).first!
    horizontal.contentView.scroll(to: CGPoint(x: 1500, y: 0))
    vertical.contentView.scroll(to: CGPoint(x: 0, y: 200)); settle(root)
    let evaluations = state.evaluations
    for width: CGFloat in [1100, 800, 960, 1280] {
        window.setContentSize(NSSize(width: width, height: 600)); settle(root)
        let actual = vertical.contentView.bounds.width
        precondition(abs(actual - width) < 0.5 && abs(vertical.documentView!.frame.width - actual) < 0.5,
                     "Vertical document must use the live clip width: requested \(width), clip \(actual), document \(vertical.documentView!.frame.width), root \(root.frame.width)")
        precondition(abs(mixer.frame.width - 300) < 0.5 && abs(divider.frame.minX - 300) < 0.5)
        precondition(abs(timeline.frame.width - (actual - 306)) < 0.5 && abs(horizontal.contentView.bounds.width - (actual - 306)) < 0.5,
                     "Timeline column and horizontal viewport must follow actual native bounds")
        precondition(abs(horizontal.contentView.bounds.minX - 1500) < 0.5 && abs(vertical.contentView.bounds.minY - 200) < 0.5,
                     "Viewport resize must retain both scroll origins")
        precondition(abs(timeline.convert(NSSize(width: 10, height: 10), to: nil).width - 10) < 0.01,
                     "Native viewport must not scale the timeline")
        precondition(state.evaluations == evaluations, "Width changes must not need model publications")
    }
    state.revision = 1; settle(root)
    precondition(descendants(WorkspaceControl.self, in: timeline).first === control && control.revision == 1)
    precondition(control.language == "pt_BR" && !control.dark && control.blocked,
                 "Native sizing must preserve live model/environment updates")
    control.actions(); precondition(state.actions == ["fx1"])
    print("NATIVE_VIEWPORT_WIDTH_WITHOUT_MODEL_PUBLICATIONS_PRESERVES_COLUMNS_SCROLL_COORDINATES_ENVIRONMENT_AND_ACTIONS_OK")
    window.close()
}
private struct MixerWidthFixture: View {
    @ObservedObject var state: MixerWidthState
    let project = UUID()
    var body: some View {
        let _ = { state.publications += 1 }()
        NativeTimelineColumns(mixerWidth: state.width, viewportWidth: 1200, height: 600, dividerWidth: 6,
                              project: project, mixerIdentity: 0, liveWidth: state.nativeWidth) {
            Color.blue
        } divider: { Color.gray } timeline: {
            GridScrollView(axis: .horizontal, contentWidth: 4000, contentHeight: 600) {
                Color.green.frame(width: 4000, height: 600)
            }
        }
        .frame(width: 1200, height: 600)
        .overlay(alignment: .topLeading) {
            NativeTimelineMixerOverlay(width: state.width, maximum: 480, minimum: 140, dividerWidth: 6,
                headerHeight: 40, liveWidth: state.nativeWidth,
                onWidthModeChanged: { state.modes.append($0 >= 180) },
                onCancel: { state.cancellations += 1 },
                onEnd: { width in state.width = width; state.commits.append(width) }) {
                    StatefulControl(role: "mixer-header", revision: 0)
                        .frame(maxWidth: .infinity).padding(.trailing, 40)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
MainActor.assumeIsolated {
    let state = MixerWidthState()
    let root = NSHostingView(rootView: MixerWidthFixture(state: state))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = root; settle(root)
    let divider = descendants(MixerDividerView.self, in: root).first!
    let mixer = descendants(NSView.self, in: root).first { $0.identifier?.rawValue == "columns-mixer" }!
    let timeline = descendants(NSView.self, in: root).first { $0.identifier?.rawValue == "columns-timeline" }!
    let scroll = descendants(GridNativeScrollView.self, in: timeline).first!
    let header = descendants(NSView.self, in: root).first { $0.identifier?.rawValue == "mixer-pinned-header" }!
    let headerControl = descendants(WorkspaceControl.self, in: header).first!
    headerControl.increment(); settle(root)
    precondition(window.makeFirstResponder(headerControl))
    scroll.contentView.scroll(to: CGPoint(x: 450, y: 0))
    let initial = divider.convert(CGPoint(x: 3, y: 40), to: nil)
    func event(_ type: NSEvent.EventType, _ delta: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: initial.x + delta, y: initial.y), modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    divider.mouseDown(with: event(.leftMouseDown, 0))
    let initialPublications = state.publications
    for delta: CGFloat in [10, 80, 40, -50, 20] {
        divider.mouseDragged(with: event(.leftMouseDragged, delta)); settle(root)
        precondition(mixer.frame.width == 300 + delta && timeline.frame.minX == 306 + delta)
        precondition(header.frame.width == 300 + delta && abs(headerControl.frame.width - (260 + delta)) < 0.01,
                     "pinned header and its icon reserve follow native widths")
        precondition(state.publications == initialPublications && state.width == 300,
                     "native pixel widths must not republish the vertical scroll/timeline roots")
        precondition(window.firstResponder === headerControl && headerControl.count == 1)
        precondition(abs(scroll.contentView.bounds.minX - 450) < 0.01)
        precondition(abs(divider.convert(CGPoint(x: 3, y: 40), to: nil).x - initial.x - delta) < 0.01,
                     "divider and actual column boundary stay together")
        precondition(abs(scroll.contentView.frame.width - (894 - delta)) < 0.01,
                     "the real timeline viewport reflows to the new available width")
        for view in descendants(NSView.self, in: root) {
            precondition(view.layer?.affineTransform().isIdentity != false,
                         "resizing must never stretch the grid, text, controls or cursor geometry")
        }
        let unit = scroll.documentView!.convert(NSSize(width: 100, height: 1), to: nil)
        precondition(abs(unit.width - 100) < 0.01, "100 timeline pixels stay 100 screen pixels during resize")
    }
    divider.mouseUp(with: event(.leftMouseUp, 30)); settle(root)
    precondition(state.width == 330 && state.commits == [330] && mixer.frame.width == 330)
    let before = state.publications
    divider.mouseDown(with: event(.leftMouseDown, 30))
    for n in 0..<200 { divider.mouseDragged(with: event(.leftMouseDragged, 30 + CGFloat(n % 50))) }
    precondition(state.publications == before, "a burst changes native frames without publishing SwiftUI roots")
    divider.mouseUp(with: event(.leftMouseUp, 65)); settle(root)
    precondition(state.width == 365 && state.commits == [330, 365] && mixer.frame.width == 365)
    let stopped = state.publications
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    precondition(state.publications == stopped, "no pending width is applied after release")
    divider.mouseDown(with: event(.leftMouseDown, 65))
    divider.mouseDragged(with: event(.leftMouseDragged, -70)); settle(root)
    divider.mouseDragged(with: event(.leftMouseDragged, -150)); settle(root)
    divider.mouseDragged(with: event(.leftMouseDragged, -155)); settle(root)
    divider.mouseDragged(with: event(.leftMouseDragged, -80)); settle(root)
    precondition(state.modes == [false, true], "only crossing the 180-point control mode publishes a semantic change")
    let committed = state.commits
    divider.cancelTracking(); settle(root)
    precondition(!state.nativeWidth.resizing && state.nativeWidth.width == nil && state.commits == committed)
    precondition(state.cancellations == 1 && mixer.frame.width == state.width && header.frame.width == state.width,
                 "cancelling restores saved native widths without persisting an abandoned drag")
    state.width = 0; settle(root)
    precondition(mixer.isHidden && header.isHidden && divider.frame.minX == 0)
    state.width = 340; settle(root)
    precondition(!mixer.isHidden && !header.isHidden && divider.frame.minX == 340 && headerControl.count == 1)
    print("TRACK_MIXER_REAL_VIEWPORT_NO_STRETCH_DIVIDER_ALIGNED_DISPLAY_CADENCE_AND_FINAL_POINTER_COMMIT_OK")
    window.close()
}

MainActor.assumeIsolated {
    let notifications = ObservableObjectPublisher()
    var values = Array(repeating: 0, count: 200)
    var deliveries = Array(repeating: 0, count: 200)
    let rows = values.indices.map { index in TimelineMixerRowUpdates(value: values[index], publisher: notifications) { values[index] } }
    let subscriptions = rows.indices.map { index in rows[index].objectWillChange.sink { deliveries[index] += 1 } }
    values[83] = 1; notifications.send()
    precondition(deliveries[83] == 1 && deliveries.reduce(0, +) == 1 && rows[83].value == 1,
                 "one mixer change must publish into only its own row graph")
    for _ in 0..<20 { notifications.send() }
    precondition(deliveries.reduce(0, +) == 1, "selection and unrelated notifications leave unchanged row graphs untouched")
    values[5] = 2; values[83] = 3; notifications.send()
    precondition(deliveries[5] == 1 && deliveries[83] == 2 && rows[83].value == 3)
    withExtendedLifetime(subscriptions) {}
    print("TRACK_MIXER_200_ROW_NOTIFICATIONS_PUBLISH_ONLY_CHANGED_CONTROL_METADATA_OK")
}
