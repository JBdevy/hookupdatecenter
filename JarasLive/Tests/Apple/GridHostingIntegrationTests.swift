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
                            NativeTimelinePinnedInput(width: viewportWidth,height: geometry.size.height,input:
                                GridSelectionInput(origin: .zero,headerHeight: headerHeight,
                                    items: [GridSelectionItem(id: state.item,rect: CGRect(x: 960,y: 630,width: 480,height: 50),name: "Hosting item header",duration: 48)],
                                    selected: [],selectionChanged: { state.selections.append($0) },mute: { _ in },move: { _,_,_,_ in },
                                    seek: { x,_ in state.seeks.append(x) },createRegion: { _ in })
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
root.layoutSubtreeIfNeeded()
RunLoop.main.run(until: Date().addingTimeInterval(0.02))
if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
    root.cacheDisplay(in: root.bounds, to: bitmap)
    let header = grid.convert(CGRect(x: 160, y: 230, width: 480, height: 17), to: root)
    let scaleX = CGFloat(bitmap.pixelsWide) / root.bounds.width
    let scaleY = CGFloat(bitmap.pixelsHigh) / root.bounds.height
    var whitePixels = 0
    for row in Int(header.minY * scaleY)..<Int(header.maxY * scaleY) {
        for column in Int(header.minX * scaleX)..<Int(header.maxX * scaleX) {
            for y in [row, bitmap.pixelsHigh - 1 - row] where y >= 0 && y < bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: column, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.8 && color.greenComponent > 0.8 && color.blueComponent > 0.8 {
                    whitePixels += 1
                }
            }
        }
    }
    precondition(whitePixels > 40, "item names and controls remain painted in the pinned overlay after both axes scroll")
} else { preconditionFailure("the hosted timeline must support visual regression capture") }
let previousSelection = state.selections.count
precondition(grid.handlePointerEvent(pointer(.leftMouseDown,CGPoint(x: 200,y: 250))))
precondition(grid.handlePointerEvent(pointer(.leftMouseUp,CGPoint(x: 200,y: 250))))
precondition(state.selections.count == previousSelection+1 && state.selections.last == [state.item],"a hosted item is selectable immediately after both native axes scroll")
let headerScreenY = headerPin.host!.convert(CGPoint.zero,to: nil).y
outer.contentView.scroll(to: CGPoint(x: 0,y: 600))
precondition(abs(headerPin.host!.convert(CGPoint.zero,to: nil).y-headerScreenY) < 0.001,"hosted ruler stays pinned through further vertical scrolling")
blankClick("further_scroll")

// The body input is authoritative below the ruler, while the needle heads,
// header and modal gates retain the ordinary AppKit routing path.
precondition(inner.timelineBodyInput === grid && outer.timelineBodyInput === grid,
             "nested native containers register the visible body input")
let bodyPoint = pointer(.mouseMoved, CGPoint(x: 340, y: 210)).locationInWindow
precondition(inner.hitTest(inner.superview!.convert(bodyPoint, from: nil)) === grid,
             "native scroll resolves the body without traversing nested SwiftUI hosts")
precondition(outer.hitTest(outer.superview!.convert(bodyPoint, from: nil)) === grid,
             "outer native scrolling bypasses unrelated mixer SwiftUI hit testing")
let mixerPoint = outer.contentView.convert(CGPoint(x: 40, y: outer.contentView.bounds.minY + 210), to: nil)
precondition(outer.hitTest(outer.superview!.convert(mixerPoint, from: nil)) !== grid,
             "the body shortcut never captures mixer controls or splitter input")
let headPoint = pointer(.mouseMoved, CGPoint(x: 340, y: 74)).locationInWindow
precondition(grid.hitTestTimelineBody(atWindowPoint: headPoint) == nil,
             "needle heads retain priority across the ruler's lower edge")
NativeTimelineInputGate.shared.setBlocked(true, for: window)
precondition(grid.hitTestTimelineBody(atWindowPoint: bodyPoint) == nil,
             "fast body routing never bypasses modal input blocking")
NativeTimelineInputGate.shared.setBlocked(false, for: window)

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

// The horizontal native document can change extent while its SwiftUI host
// stays viewport-sized. Equal host frame/bounds origins retain document-space
// rendering and AppKit hit targets at the far right of a long timeline.
private final class VirtualViewportProbeView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { NSColor.red.setFill(); bounds.fill() }
}
private struct VirtualViewportProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> VirtualViewportProbeView { VirtualViewportProbeView() }
    func updateNSView(_ view: VirtualViewportProbeView, context: Context) {}
}
private struct VirtualViewportFixture: View {
    let state: TimelineZoomState
    let counters: ZoomLayoutCounters
    var documentHeight: CGFloat = 300
    var blocked = false
    var usesLogicalBridge = true
    var body: some View {
        let _ = counters.parent += 1
        GridScrollView(axis: .horizontal, contentWidth: 3000, contentHeight: documentHeight, viewportWidth: 800) {
            TimelineZoomLayer(state: state) { zoom in
                let _ = counters.document += 1
                let width = 3000 * zoom.wrappedValue
                ZStack(alignment: .topLeading) {
                    Color.black
                    VirtualViewportProbe().frame(width: 80, height: 60).offset(x: width - 200, y: 110)
                    Text("End").foregroundStyle(.white).offset(x: width - 200, y: 80)
                }
                .frame(width: width, height: documentHeight, alignment: .topLeading)
                .background {
                    if usesLogicalBridge { GridDocumentSizeInput(width: width, height: documentHeight) }
                }
            }
        }.frame(width: 800, height: 300).environment(\.gridInteractionBlocked, blocked)
    }
}
private let virtualZoom = TimelineZoomState()
virtualZoom.value = 1
private let virtualCounters = ZoomLayoutCounters()
private let virtualWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
virtualWindow.isReleasedWhenClosed = false
private let virtualRoot = NSHostingView(rootView: VirtualViewportFixture(state: virtualZoom, counters: virtualCounters))
virtualWindow.contentView = virtualRoot
virtualRoot.layoutSubtreeIfNeeded()
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
private let virtualScroll = allDescendants(GridNativeScrollView.self, in: virtualRoot).first!
private let virtualDocument = virtualScroll.documentView!
private let virtualHost = virtualDocument.subviews.first!
private let virtualProbe = allDescendants(VirtualViewportProbeView.self, in: virtualHost).first!
private let virtualParentBuilds = virtualCounters.parent
private var virtualCapacity: CGFloat = 3000
for width: CGFloat in [3000, 6000, 1400, 7500, 2600] {
    virtualCapacity = width > virtualCapacity ? max(width, virtualCapacity * 2) : virtualCapacity
    virtualScroll.zoomAnchor = (0.65, 400, width)
    virtualZoom.value = width / 3000
    // A same-value first case still asks the existing host to commit the anchor.
    virtualHost.needsLayout = true
    RunLoop.main.run(until: Date().addingTimeInterval(0.025))
    virtualRoot.layoutSubtreeIfNeeded()
    let anchoredX = min(max(0, 0.65 * width - 400), width - 800)
    precondition(virtualScroll.zoomAnchor == nil && abs(virtualScroll.contentView.bounds.minX - anchoredX) < 0.001,
                 "virtual document size and zoom anchor commit at the same scale")
    precondition(abs(virtualScroll.contentView.documentRect.width - width) < 0.001 && virtualDocument.frame.width == virtualCapacity && virtualHost.frame.width == 800,
                 "logical extent scales while native capacity and hosting viewport remain retained")
    virtualScroll.contentView.scroll(to: CGPoint(x: width - 800, y: 0))
    virtualScroll.reflectScrolledClipView(virtualScroll.contentView)
    precondition(virtualHost.frame.minX == virtualScroll.contentView.bounds.minX &&
                 virtualHost.bounds.minX == virtualScroll.contentView.bounds.minX,
                 "frame and bounds origins follow native scrolling immediately")
    virtualRoot.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.010))
    precondition(allDescendants(VirtualViewportProbeView.self, in: virtualHost).first === virtualProbe,
                 "zoom retains existing native controls inside the stable host")
    let probeRect = virtualProbe.convert(virtualProbe.bounds, to: virtualDocument)
    precondition(abs(probeRect.minX - (width - 200)) < 0.001 && probeRect.minY == 110,
                 "virtual hosting never recenters or shifts descendant document coordinates")
    let documentPoint = CGPoint(x: width - 160, y: 140)
    let rootPoint = virtualRoot.convert(documentPoint, from: virtualDocument)
    precondition(virtualRoot.hitTest(rootPoint) === virtualProbe,
                 "AppKit reaches a native control after scrolling beyond the initial host frame")
    guard let bitmap = virtualRoot.bitmapImageRepForCachingDisplay(in: virtualRoot.bounds) else {
        preconditionFailure("virtual hosting fixture supports a visible pixel check")
    }
    virtualRoot.cacheDisplay(in: virtualRoot.bounds, to: bitmap)
    let scaleX = CGFloat(bitmap.pixelsWide) / virtualRoot.bounds.width
    let scaleY = CGFloat(bitmap.pixelsHigh) / virtualRoot.bounds.height
    var redPixels = 0
    for x in 615..<665 {
        for y in [130, 140, 150, 160] {
            if let color = bitmap.colorAt(x: Int(CGFloat(x) * scaleX), y: Int(CGFloat(y) * scaleY))?.usingColorSpace(.deviceRGB),
               color.redComponent > 0.7, color.greenComponent < 0.4, color.blueComponent < 0.4 { redPixels += 1 }
        }
    }
    precondition(redPixels > 20, "the far-right item stays painted at its correct screen position at every scale")
}
precondition(virtualCounters.parent == virtualParentBuilds,
             "native logical size changes never rebuild the enclosing scroll/mixer owner")
virtualZoom.value = 2
RunLoop.main.run(until: Date().addingTimeInterval(0.025))
virtualRoot.layoutSubtreeIfNeeded()
virtualScroll.contentView.scroll(to: CGPoint(x: 5200, y: 0))
virtualScroll.reflectScrolledClipView(virtualScroll.contentView)
private var refreshedDocumentWidths: [CGFloat] = []
virtualDocument.postsFrameChangedNotifications = true
private let refreshObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
    object: virtualDocument, queue: .main) { _ in refreshedDocumentWidths.append(virtualDocument.frame.width) }
// The outer representable deliberately still captures width 3000. Updating
// an environment value and structural row height must not temporarily shrink
// the committed width 6000 and clamp the user's far-right viewport.
virtualRoot.rootView = VirtualViewportFixture(state: virtualZoom, counters: virtualCounters,
    documentHeight: 420, blocked: true)
RunLoop.main.run(until: Date().addingTimeInterval(0.025))
virtualRoot.layoutSubtreeIfNeeded()
precondition(virtualDocument.frame.size == CGSize(width: virtualCapacity, height: 420) && virtualScroll.contentView.documentRect.width == 6000 && virtualHost.frame.size == CGSize(width: 800, height: 420),
             "outer environment/row-height updates preserve the live bridge width while applying the new height")
precondition(refreshedDocumentWidths.allSatisfy { $0 == virtualCapacity } && virtualScroll.contentView.bounds.minX == 5200,
             "refresh never briefly reapplies stale width and clamps horizontal scrolling")
NotificationCenter.default.removeObserver(refreshObserver)
// Keep a removed bridge alive to prove document authority checks attachment,
// rather than relying solely on weak-reference deallocation.
private let detachedBridge = allDescendants(GridDocumentSizeView.self, in: virtualHost).first!
virtualRoot.rootView = VirtualViewportFixture(state: virtualZoom, counters: virtualCounters,
    documentHeight: 420, blocked: false, usesLogicalBridge: false)
RunLoop.main.run(until: Date().addingTimeInterval(0.025))
virtualRoot.layoutSubtreeIfNeeded()
precondition(!detachedBridge.isDescendant(of: virtualDocument), "the bridge detaches when its logical size scope disappears")
virtualRoot.rootView = VirtualViewportFixture(state: virtualZoom, counters: virtualCounters,
    documentHeight: 430, blocked: true, usesLogicalBridge: false)
RunLoop.main.run(until: Date().addingTimeInterval(0.025))
virtualRoot.layoutSubtreeIfNeeded()
precondition(virtualDocument.frame.size == CGSize(width: 3000, height: 430),
             "a retained detached bridge never prevents a structural owner from resuming document sizing")
virtualWindow.close()
print("VIEWPORT_HOSTING_LOGICAL_EXTENT_ANCHOR_FAR_RIGHT_GEOMETRY_HIT_AND_PIXELS_OK")
print("VIEWPORT_HOSTING_ROOT_REFRESH_PRESERVES_LIVE_WIDTH_AND_UPDATES_HEIGHT_OK")

// Production uses one retained document coordinate plane rather than moving a
// viewport-sized host. Independent scale observers project the body and pinned
// header without reconstructing their parent/native hosting roots each frame.
private final class CoordinatePlaneCounters {
    var parent = 0, plane = 0, body = 0, header = 0
}
private final class CoordinatePlaneControlView: NSView {
    var header = false
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        (header ? NSColor.green : NSColor.red).setFill()
        bounds.fill()
    }
}
private struct CoordinatePlaneControl: NSViewRepresentable {
    let header: Bool
    func makeNSView(context: Context) -> CoordinatePlaneControlView {
        let view = CoordinatePlaneControlView()
        view.header = header
        return view
    }
    func updateNSView(_ view: CoordinatePlaneControlView, context: Context) { view.header = header }
}
private struct CoordinatePlaneFixture: View {
    let state: TimelineZoomState
    let counters: CoordinatePlaneCounters
    var documentHeight: CGFloat = 300
    var blocked = false
    var body: some View {
        let _ = counters.parent += 1
        GridScrollView(axis: .horizontal, contentWidth: 3000, contentHeight: documentHeight) {
            TimelineCoordinatePlaneLayer(state: state, extent: 300) { planeWidth in
                let _ = counters.plane += 1
                ZStack(alignment: .topLeading) {
                    Color.black
                    TimelineScaleLayer(state: state, extent: 300) { _, width, _ in
                        let _ = counters.body += 1
                        CoordinatePlaneControl(header: false)
                            .frame(width: 80, height: 60).offset(x: width - 200, y: 110)
                            .frame(width: planeWidth, height: documentHeight, alignment: .topLeading)
                    }
                    NativeTimelinePinnedLayer(width: planeWidth, height: 55, content:
                        TimelineScaleLayer(state: state, extent: 300) { _, width, _ in
                            let _ = counters.header += 1
                            ZStack(alignment: .topLeading) {
                                CoordinatePlaneControl(header: true)
                                    .frame(width: 100, height: 30).offset(x: width - 160, y: 15)
                                Text("Far-right header").foregroundStyle(.white)
                                    .frame(width: 130, height: 25).offset(x: width - 350, y: 15)
                            }.frame(width: planeWidth, height: 55, alignment: .topLeading)
                        }
                    ).frame(width: planeWidth, height: 55)
                }.frame(width: planeWidth, height: documentHeight, alignment: .topLeading)
                .background {
                    TimelineScaleLayer(state: state, extent: 300) { _, width, _ in
                        GridDocumentSizeInput(width: width, height: documentHeight, hostingWidth: planeWidth)
                    }
                }
            }
        }.frame(width: 800, height: 300).environment(\.gridInteractionBlocked, blocked)
    }
}
private let planeZoom = TimelineZoomState()
planeZoom.value = 1
private let planeCounters = CoordinatePlaneCounters()
private let planeWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
planeWindow.isReleasedWhenClosed = false
private let planeRoot = NSHostingView(rootView: CoordinatePlaneFixture(state: planeZoom, counters: planeCounters))
planeWindow.contentView = planeRoot
planeRoot.layoutSubtreeIfNeeded()
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
planeRoot.layoutSubtreeIfNeeded()
private let planeScroll = allDescendants(GridNativeScrollView.self, in: planeRoot).first!
private let planeDocument = planeScroll.documentView!
private let planeHost = planeDocument.subviews.first!
private let planeControls = allDescendants(CoordinatePlaneControlView.self, in: planeHost)
private let planeBodyControl = planeControls.first { !$0.header }!
private let planeHeaderControl = planeControls.first { $0.header }!
private let planeParentBuilds = planeCounters.parent
private let planeBodyBuilds = planeCounters.body, planeHeaderBuilds = planeCounters.header
private var previousCapacity: CGFloat = 3000
private var previousPlaneBuilds = planeCounters.plane
private var planeFrameChanges = 0
planeDocument.postsFrameChangedNotifications = true
private let planeFrameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
    object: planeDocument, queue: .main) { _ in planeFrameChanges += 1 }
for width: CGFloat in [3000, 4500, 3200, 5900, 1200, 6100, 4000] {
    let expectedCapacity = width > previousCapacity ? max(width, previousCapacity * 2) : previousCapacity
    let frameChangesBeforeZoom = planeFrameChanges
    planeScroll.zoomAnchor = (0.65, 400, width)
    planeZoom.value = width / 3000
    planeHost.needsLayout = true
    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    planeRoot.layoutSubtreeIfNeeded()
    let anchoredX = min(max(0, 0.65 * width - 400), width - 800)
    precondition(planeScroll.zoomAnchor == nil && abs(planeScroll.contentView.bounds.minX - anchoredX) < 0.001,
                 "coordinate plane commits logical width and anchor at the same scale")
    precondition(abs(planeScroll.contentView.documentRect.width - width) < 0.001 && planeDocument.frame.width == expectedCapacity && planeHost.frame.width == expectedCapacity,
                 "logical scroll extent changes while the native document and full host retain capacity")
    if expectedCapacity == previousCapacity {
        precondition(planeCounters.plane == previousPlaneBuilds, "zoom within capacity never rebuilds the coordinate-plane scope")
        precondition(planeFrameChanges == frameChangesBeforeZoom,
                     "zoom within capacity does not post any native document frame change")
    }
    let clip = planeScroll.contentView
    let constrained = clip.constrainBoundsRect(CGRect(x: expectedCapacity + 1000, y: 0, width: 800, height: 300))
    precondition(constrained.minX == width - 800, "proposed scrolling clamps to logical end, never unused capacity")
    clip.setBoundsOrigin(CGPoint(x: expectedCapacity + 1000, y: 0))
    precondition(clip.bounds.minX == width - 800, "direct momentum bounds changes clamp to logical end")
    clip.setBoundsOrigin(CGPoint(x: -1000, y: 0))
    precondition(clip.bounds.minX == 0, "direct momentum cannot cross time zero")
    planeScroll.contentView.scroll(to: CGPoint(x: width - 800, y: 0))
    planeScroll.reflectScrolledClipView(planeScroll.contentView)
    precondition(planeHost.frame.origin == .zero && planeHost.bounds.origin == .zero,
                 "the retained document host keeps coordinate origin zero even at the far right")
    planeRoot.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    let controls = allDescendants(CoordinatePlaneControlView.self, in: planeHost)
    precondition(controls.contains { $0 === planeBodyControl } && controls.contains { $0 === planeHeaderControl },
                 "both scale observers retain their existing native body and header controls")
    let bodyRect = planeBodyControl.convert(planeBodyControl.bounds, to: planeDocument)
    let headerRect = planeHeaderControl.convert(planeHeaderControl.bounds, to: planeDocument)
    precondition(abs(bodyRect.minX - (width - 200)) < 0.001 && bodyRect.minY == 110 && bodyRect.size == CGSize(width: 80, height: 60),
                 "body controls keep their pixel size and document coordinates at every scale")
    precondition(abs(headerRect.minX - (width - 160)) < 0.001 && headerRect.minY == 15 && headerRect.size == CGSize(width: 100, height: 30),
                 "the localized header observer updates far-right geometry without scaling its controls")
    for control in [planeBodyControl, planeHeaderControl] {
        let screenPoint = control.convert(CGPoint(x: 30, y: 20), to: planeRoot)
        // NSView.hitTest takes the superview's coordinate system. The window
        // frame is unflipped, unlike this SwiftUI root and timeline controls.
        let hit = planeRoot.hitTest(planeRoot.convert(screenPoint, to: planeRoot.superview))
        precondition(hit === control, "far-right body and pinned header hit testing follows live scale")
    }
    guard let bitmap = planeRoot.bitmapImageRepForCachingDisplay(in: planeRoot.bounds) else {
        preconditionFailure("retained coordinate plane supports visible pixel verification")
    }
    planeRoot.cacheDisplay(in: planeRoot.bounds, to: bitmap)
    let densityX = CGFloat(bitmap.pixelsWide) / planeRoot.bounds.width
    let densityY = CGFloat(bitmap.pixelsHigh) / planeRoot.bounds.height
    for control in [planeBodyControl, planeHeaderControl] {
        let point = control.convert(CGPoint(x: 30, y: 20), to: planeRoot)
        let pixelX = Int(point.x * densityX), pixelY = Int(point.y * densityY)
        let drawn = [pixelY, bitmap.pixelsHigh - 1 - pixelY].contains { row in
            guard row >= 0, row < bitmap.pixelsHigh,
                  let color = bitmap.colorAt(x: pixelX, y: row)?.usingColorSpace(.deviceRGB) else { return false }
            // The physical display profile can mix the device-RGB primaries;
            // require clear channel dominance instead of literal sRGB zeroes.
            return control.header ? color.greenComponent > 0.7 && color.greenComponent > color.redComponent + 0.2
                : color.redComponent > 0.7 && color.redComponent > color.greenComponent + 0.2
        }
        if !drawn {
            if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: "/tmp/catlive-plane-hosting-failure.png")) }
            FileHandle.standardError.write(Data("PLANE_PIXEL_FAILURE width=\(width) header=\(control.header) point=\(point) bitmap=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh)\n".utf8))
        }
        precondition(drawn, "the far-right body and header remain visibly painted at the current scale")
    }
    previousCapacity = expectedCapacity
    previousPlaneBuilds = planeCounters.plane
}
precondition(planeCounters.parent == planeParentBuilds && planeCounters.body > planeBodyBuilds && planeCounters.header > planeHeaderBuilds,
             "scale updates independent body and pinned-header scopes without rebuilding their structural owner")
planeRoot.rootView = CoordinatePlaneFixture(state: planeZoom, counters: planeCounters, documentHeight: 420, blocked: true)
RunLoop.main.run(until: Date().addingTimeInterval(0.03))
planeRoot.layoutSubtreeIfNeeded()
precondition(planeDocument.frame.size == CGSize(width: previousCapacity, height: 420) && planeScroll.contentView.documentRect.width == 4000 && planeHost.frame.size == CGSize(width: previousCapacity, height: 420),
             "structural row-height changes retain both live logical width and hosting capacity")
precondition(planeHost.frame.origin == .zero && planeHost.bounds.origin == .zero)
// A logical document shorter than the viewport still reports its exact scale;
// the excess physical capacity must not create an invisible scrollable tail.
planeZoom.value = 0.2
RunLoop.main.run(until: Date().addingTimeInterval(0.03))
planeRoot.layoutSubtreeIfNeeded()
planeScroll.contentView.scroll(to: CGPoint(x: previousCapacity, y: 0))
precondition(planeScroll.contentView.documentRect.width == 600 && planeScroll.contentView.bounds.minX == 0)
precondition(planeDocument.frame.width == previousCapacity && planeDocument.frame.height == 420,
             "zoom below viewport size retains capacity and structural row height")
NotificationCenter.default.removeObserver(planeFrameObserver)
planeWindow.close()
print("RETAINED_DOCUMENT_CAPACITY_NO_ZOOM_FRAME_NOTIFICATIONS_AND_LOGICAL_MOMENTUM_BOUNDS_OK")
print("RETAINED_COORDINATE_PLANE_LOCALIZED_SCALE_LOGICAL_EXTENT_FIXED_CONTROLS_FAR_RIGHT_HEADER_AND_PIXELS_OK")

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
