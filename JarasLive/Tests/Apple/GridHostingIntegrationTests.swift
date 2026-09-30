import SwiftUI
import AppKit

final class HostingFixtureState {
    var seeks: [CGFloat] = []
    var selections: [Set<UUID>] = []
    let item = UUID()
}
struct HostedTimelineFixture: View {
    let state: HostingFixtureState
    let documentWidth: CGFloat = 3_000
    let documentHeight: CGFloat = 1_600
    let mixerWidth: CGFloat = 154
    let headerHeight: CGFloat = 71
    var body: some View {
        GeometryReader { geometry in
            let viewportWidth = geometry.size.width - mixerWidth
            GridScrollView(axis: .vertical,contentWidth: geometry.size.width,contentHeight: documentHeight) {
                HStack(alignment: .top,spacing: 0) {
                    Color.gray.frame(width: mixerWidth,height: documentHeight)
                    GridScrollView(axis: .horizontal,contentWidth: documentWidth,contentHeight: documentHeight) {
                        ZStack(alignment: .topLeading) {
                            Color.black.frame(width: documentWidth,height: documentHeight)
                            NativeTimelinePinnedLayer(width: documentWidth,height: documentHeight,content:
                                Color.green.opacity(0.2).frame(width: documentWidth,height: headerHeight)
                                    .frame(width: documentWidth,height: documentHeight,alignment: .topLeading)
                            ).frame(width: documentWidth,height: documentHeight)
                        }
                        .overlay(alignment: .topLeading) {
                            NativeTimelinePinnedLayer(width: viewportWidth,height: geometry.size.height,pinHorizontally: true,content:
                                GridSelectionInput(origin: .zero,headerHeight: headerHeight,
                                    items: [GridSelectionItem(id: state.item,rect: CGRect(x: 960,y: 630,width: 120,height: 50))],
                                    selected: [],selectionChanged: { state.selections.append($0) },mute: { _ in },move: { _,_,_,_ in },
                                    seek: { x,_ in state.seeks.append(x) },createRegion: { _ in })
                                    .frame(width: viewportWidth,height: geometry.size.height)
                            ).frame(width: documentWidth,height: documentHeight,alignment: .topLeading)
                        }
                        .frame(width: documentWidth,height: documentHeight,alignment: .topLeading)
                    }.frame(width: viewportWidth,height: documentHeight)
                }.frame(width: geometry.size.width,height: documentHeight,alignment: .topLeading)
            }.frame(width: geometry.size.width,height: geometry.size.height)
        }
    }
}
func allDescendants<T: NSView>(_ type: T.Type,in view: NSView) -> [T] {
    var result: [T] = []
    if let match = view as? T { result.append(match) }
    for child in view.subviews { result.append(contentsOf: allDescendants(type,in: child)) }
    return result
}
let app = NSApplication.shared
let state = HostingFixtureState()
let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 800,height: 600),styleMask: [.titled],backing: .buffered,defer: false)
window.isReleasedWhenClosed = false
let root = NSHostingView(rootView: HostedTimelineFixture(state: state))
window.contentView = root
root.layoutSubtreeIfNeeded()
RunLoop.main.run(until: Date().addingTimeInterval(0.080))
root.layoutSubtreeIfNeeded()
let scrolls = allDescendants(GridNativeScrollView.self,in: root)
let grids = allDescendants(GridSelectionView.self,in: root)
let pins = allDescendants(NativeTimelinePinnedView.self,in: root)
precondition(scrolls.count == 2 && grids.count == 1 && pins.count == 2,"actual SwiftUI representables build the nested native timeline hierarchy")
let outer = scrolls[0], inner = scrolls[1], grid = grids[0]
let selectionPin = pins.first { $0.pinHorizontally }!
let headerPin = pins.first { !$0.pinHorizontally }!
func dumpGeometry(_ label: String) {
    let viewport = grid.convert(inner.contentView.bounds,from: inner.contentView).intersection(grid.convert(outer.contentView.bounds,from: outer.contentView))
    print("HOSTING_GEOMETRY " + label + " outer=" + NSStringFromRect(outer.contentView.bounds) + " inner=" + NSStringFromRect(inner.contentView.bounds) + " selectionPin=" + NSStringFromRect(selectionPin.frame) + " host=" + NSStringFromRect(selectionPin.host!.frame) + " grid=" + NSStringFromRect(grid.frame) + " viewport=" + NSStringFromRect(viewport) + " hidden=" + String(grid.isHiddenOrHasHiddenAncestor))
}
func pointer(_ type: NSEvent.EventType,_ viewportPoint: CGPoint) -> NSEvent {
    let point = CGPoint(x: viewportPoint.x + 154,y: viewportPoint.y + outer.contentView.bounds.minY)
    return NSEvent.mouseEvent(with: type,location: outer.contentView.convert(point,to: nil),modifierFlags: [],timestamp: ProcessInfo.processInfo.systemUptime,windowNumber: window.windowNumber,context: nil,eventNumber: 1,clickCount: 1,pressure: 1)!
}
func blankClick(_ label: String) {
    dumpGeometry(label)
    let previous = state.seeks.count
    let down = grid.handlePointerEvent(pointer(.leftMouseDown,CGPoint(x: 340,y: 210)))
    let up = grid.handlePointerEvent(pointer(.leftMouseUp,CGPoint(x: 340,y: 210)))
    print("HOSTING_CLICK " + label + " down=" + String(down) + " up=" + String(up) + " seeks=" + String(state.seeks.count-previous))
    precondition(down && up && state.seeks.count == previous+1,"a blank grid click moves the green edit needle in the actual hosting hierarchy")
    precondition(abs(state.seeks.last!-(inner.contentView.bounds.minX+340)) < 0.001,"hosted input uses exact live horizontal scroll coordinates")
}
blankClick("initial")
inner.contentView.scroll(to: CGPoint(x: 800,y: 0))
outer.contentView.scroll(to: CGPoint(x: 0,y: 400))
blankClick("scrolled_before_host_render")
let previousSelection = state.selections.count
precondition(grid.handlePointerEvent(pointer(.leftMouseDown,CGPoint(x: 200,y: 250))))
precondition(grid.handlePointerEvent(pointer(.leftMouseUp,CGPoint(x: 200,y: 250))))
precondition(state.selections.count == previousSelection+1 && state.selections.last == [state.item],"a hosted item is selectable immediately after both native axes scroll")
let headerScreenY = headerPin.host!.convert(CGPoint.zero,to: nil).y
outer.contentView.scroll(to: CGPoint(x: 0,y: 600))
precondition(abs(headerPin.host!.convert(CGPoint.zero,to: nil).y-headerScreenY) < 0.001,"hosted ruler stays pinned through further vertical scrolling")
blankClick("further_scroll")

// SwiftUI can temporarily retain obsolete representables in the same window.
// Newer stale monitors must pass the event through to the visible input host.
final class ClippedInputContainer: NSView { override var isFlipped: Bool { true } }
var staleSeeks: [CGFloat] = []
let zeroInput = GridSelectionView(frame: .zero)
zeroInput.seek = { x,_ in staleSeeks.append(x) }
inner.documentView!.addSubview(zeroInput)
let clippedContainer = ClippedInputContainer(frame: NSRect(x: 0,y: 0,width: 20,height: 20))
clippedContainer.wantsLayer = true
clippedContainer.layer?.masksToBounds = true
let clippedInput = GridSelectionView(frame: NSRect(x: 0,y: 0,width: 3_000,height: 1_600))
clippedInput.seek = { x,_ in staleSeeks.append(x) }
clippedContainer.addSubview(clippedInput)
inner.documentView!.addSubview(clippedContainer)
let hiddenInput = GridSelectionView(frame: NSRect(x: 0,y: 0,width: 3_000,height: 1_600))
hiddenInput.seek = { x,_ in staleSeeks.append(x) }; hiddenInput.isHidden = true
inner.documentView!.addSubview(hiddenInput)
let dispatchedDown = pointer(.leftMouseDown,CGPoint(x: 340,y: 210))
let clippedPoint = clippedInput.convert(dispatchedDown.locationInWindow,from: nil)
precondition(clippedInput.bounds.contains(clippedPoint) && !clippedInput.visibleRect.contains(clippedPoint),"fixture isolates clipping from the stale view's own full-sized bounds")
for stale in [zeroInput,clippedInput,hiddenInput] {
    precondition(!stale.handlePointerEvent(dispatchedDown),"zero-sized, clipped and hidden stale hosts never claim another input host's click")
}
let dispatchedSeekCount = state.seeks.count
app.sendEvent(dispatchedDown)
app.sendEvent(pointer(.leftMouseUp,CGPoint(x: 340,y: 210)))
print("HOSTING_DISPATCH seeks=" + String(state.seeks.count-dispatchedSeekCount))
precondition(staleSeeks.isEmpty && state.seeks.count == dispatchedSeekCount+1,"AppKit dispatch bypasses retained stale monitors and reaches the visible hosting input exactly once")
precondition(abs(state.seeks.last!-(inner.contentView.bounds.minX+340)) < 0.001,"stale monitors cannot redirect the green needle with an obsolete seek closure")
window.close()
print("GRID_SWIFTUI_HOSTING_PINNED_INPUT_SEEK_SELECTION_AND_SCROLL_OK")

struct NormalizationFixtureClip { let id: UUID; var audioFile: Bool? = true }
struct NormalizationFixtureTrack { enum Kind { case standard, video }; let kind: Kind; let clips: [NormalizationFixtureClip] }
struct NormalizationFixtureSong { let tracks: [NormalizationFixtureTrack] }
final class NormalizationFixtureShow: ObservableObject {
    @Published var normalizeItemsRequest: UInt64 = 0
    let audio = UUID(), video = UUID(), silent = UUID()
    var current: NormalizationFixtureSong? { NormalizationFixtureSong(tracks: [
        NormalizationFixtureTrack(kind: .standard, clips: [NormalizationFixtureClip(id: audio), NormalizationFixtureClip(id: silent, audioFile: nil)]),
        NormalizationFixtureTrack(kind: .video, clips: [NormalizationFixtureClip(id: video)])]) }
    var displayed: [Set<UUID>] = []
}
struct NormalizationFixtureRoot: View {
    @ObservedObject var show: NormalizationFixtureShow
    var body: some View { NormalizationFixtureContent(show: show).equatable() }
}
struct NormalizationFixtureContent: View, Equatable {
    let show: NormalizationFixtureShow
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.show === rhs.show }
    @State private var showingNormalize = false
    @State private var normalizingItems = Set<UUID>()
    var gridInteractionBlocked = false
    var selectedClips: Set<UUID> { [show.audio, show.video, show.silent] }
    var body: some View {
        Text(showingNormalize ? "Normalize" : "Grid").frame(width: 200, height: 100)
            NORMALIZATION_NOTIFICATION
            .onChange(of: showingNormalize) { if $0 { show.displayed.append(normalizingItems) } }
    }
}
let normalizationShow = NormalizationFixtureShow()
let normalizationWindow = NSWindow(contentRect: CGRect(x: 0,y: 0,width: 200,height: 100),styleMask: [.titled],backing: .buffered,defer: false)
normalizationWindow.isReleasedWhenClosed = false
let normalizationRoot = NSHostingView(rootView: NormalizationFixtureRoot(show: normalizationShow))
normalizationWindow.contentView = normalizationRoot
normalizationRoot.layoutSubtreeIfNeeded()
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
normalizationShow.normalizeItemsRequest += 1
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
precondition(normalizationShow.displayed == [[normalizationShow.audio]], "N reaches the equatable grid and opens normalize only for selected audio items")
normalizationShow.normalizeItemsRequest += 1
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
precondition(normalizationShow.displayed.count == 1, "requesting normalize while its editor is open never opens a second editor")
normalizationWindow.close()
print("NORMALIZATION_ACTION_EQUATABLE_GRID_DELIVERY_SELECTED_AUDIO_FILTER_AND_SINGLE_EDITOR_OK")

private final class ZoomLayoutCounters {
    var parent = 0
    var document = 0
}
private struct IsolatedZoomFixture: View {
    let state: TimelineZoomState
    let counters: ZoomLayoutCounters
    var body: some View {
        let _ = counters.parent += 1
        TimelineZoomLayer(state: state) { zoom in
            let _ = counters.document += 1
            let width = 3000 * zoom.wrappedValue
            GridScrollView(axis: .horizontal, contentWidth: width, contentHeight: 300) {
                Color.green.frame(width: width, height: 300)
            }.frame(width: 800, height: 300)
        }
    }
}
private let isolatedZoom = TimelineZoomState()
isolatedZoom.value = 1
private let zoomCounters = ZoomLayoutCounters()
private let zoomWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
zoomWindow.isReleasedWhenClosed = false
private let zoomRoot = NSHostingView(rootView: IsolatedZoomFixture(state: isolatedZoom, counters: zoomCounters))
zoomWindow.contentView = zoomRoot
zoomRoot.layoutSubtreeIfNeeded()
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
private let zoomScroll = allDescendants(GridNativeScrollView.self, in: zoomRoot).first!
private let parentBuilds = zoomCounters.parent
private let documentBuilds = zoomCounters.document
zoomScroll.zoomAnchor = (0.5, 400, 6000)
isolatedZoom.value = 2
precondition(zoomScroll.contentView.bounds.minX == 0, "zoom must not scroll before the new document layout")
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
zoomRoot.layoutSubtreeIfNeeded()
precondition(zoomCounters.parent == parentBuilds && zoomCounters.document > documentBuilds,
             "horizontal zoom updates its document without rebuilding the parent and mixer")
precondition(zoomScroll.zoomAnchor == nil && abs(zoomScroll.contentView.bounds.minX - 2600) < 1,
             "new document scale and centered viewport commit in the same layout")
zoomWindow.close()
print("ZOOM_ISOLATED_FROM_MIXER_AND_ANCHOR_COMMITTED_AFTER_LAYOUT_OK")

private final class HostedControlProbe: NSView {
    var count = 0
    var revision = 0
    var blocked = false
    var edit: () -> Void = {}
    var open: () -> Void = {}
    var details: () -> Void = {}
}
private struct HostedControlProbeRepresentable: NSViewRepresentable {
    let count: Int
    let revision: Int
    let edit: () -> Void
    let open: () -> Void
    let details: () -> Void
    @Environment(\.gridInteractionBlocked) private var blocked
    func makeNSView(context: Context) -> HostedControlProbe { HostedControlProbe() }
    func updateNSView(_ view: HostedControlProbe, context: Context) {
        view.count = count; view.revision = revision; view.blocked = blocked
        view.edit = edit; view.open = open; view.details = details
    }
}
private struct PersistentHostedControl: View {
    let revision: Int
    @State private var count = 0
    @Environment(\.openFX) private var openFX
    @Environment(\.editTrackDetails) private var editTrackDetails
    var body: some View {
        HostedControlProbeRepresentable(count: count, revision: revision,
                                        edit: { count += 1 }, open: { openFX(nil, "eq") },
                                        details: { editTrackDetails(TrackDetailsEditRequest(project: detailsProject,
                                            tracks: detailsTracks, name: "Captured", color: UInt32(revision), nameEditable: false)) })
            .frame(width: 100, height: 40)
    }
}
private let detailsProject = UUID()
private let detailsTracks: Set<UUID> = [UUID(), UUID()]
private final class HostedResizeState: ObservableObject {
    @Published var revision = 0
    var opened: [Int] = []
    var details: [(Int, TrackDetailsEditRequest)] = []
}
private struct HostedResizeFixture: View {
    @ObservedObject var state: HostedResizeState
    var body: some View {
        let revision = state.revision
        GeometryReader { geometry in
            GridScrollView(axis: .vertical, contentWidth: geometry.size.width, contentHeight: 1200) {
                PersistentHostedControl(revision: revision)
                    .frame(width: geometry.size.width, height: 1200, alignment: .topLeading)
            }
        }
        .environment(\.gridInteractionBlocked, revision % 2 == 1)
        .environment(\.openFX, { _, _ in state.opened.append(revision) })
        .environment(\.editTrackDetails, { state.details.append((revision, $0)) })
    }
}
private let resizeState = HostedResizeState()
private let resizeWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
resizeWindow.isReleasedWhenClosed = false
private let resizeRoot = NSHostingView(rootView: HostedResizeFixture(state: resizeState))
resizeWindow.contentView = resizeRoot
resizeRoot.layoutSubtreeIfNeeded()
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
private let retainedControl = allDescendants(HostedControlProbe.self, in: resizeRoot).first!
private let retainedScroll = allDescendants(GridNativeScrollView.self, in: resizeRoot).first!
retainedControl.edit()
RunLoop.main.run(until: Date().addingTimeInterval(0.02))
precondition(retainedControl.count == 1, "the hosted control accepts edits before resizing")
for revision in 1...8 {
    resizeState.revision = revision
    resizeWindow.setContentSize(CGSize(width: 500 + revision * 13, height: 300 + revision * 7))
    resizeRoot.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    resizeRoot.layoutSubtreeIfNeeded()
    precondition(allDescendants(HostedControlProbe.self, in: resizeRoot).first === retainedControl,
                 "resizing updates the existing native controls rather than replacing their view hierarchy")
    precondition(retainedControl.count == 1 && retainedControl.revision == revision,
                 "stateful edits survive each new typed hosting root while content updates remain current")
    precondition(retainedControl.blocked == (revision % 2 == 1), "modal input blocking crosses the hosting boundary without a stale environment")
    precondition(abs(retainedScroll.documentView!.frame.width - CGFloat(500 + revision * 13)) < 0.001,
                 "document geometry follows every resize without a delayed final layout")
    retainedControl.details()
    let (handlerRevision, request) = resizeState.details.last!
    precondition(handlerRevision == revision && request.color == UInt32(revision), "track edit actions cross hosting with current callbacks")
    precondition(request.project == detailsProject && request.tracks == detailsTracks && !request.nameEditable,
                 "batch edit preserves the menu's captured project, targets and color-only mode")
    retainedControl.open()
    precondition(resizeState.opened.last == revision, "stable hosted actions always forward to the latest parent handler")
}
retainedControl.edit()
RunLoop.main.run(until: Date().addingTimeInterval(0.02))
precondition(retainedControl.count == 2, "the retained control continues editing after resize")
resizeWindow.close()
print("HOSTED_RESIZE_PRESERVES_NATIVE_CONTROLS_STATE_LIVE_ENVIRONMENT_ACTIONS_AND_DOCUMENT_GEOMETRY_OK")
