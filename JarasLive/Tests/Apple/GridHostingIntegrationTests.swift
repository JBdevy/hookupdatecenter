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
                                    seek: { state.seeks.append($0) },createRegion: { _ in })
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
zeroInput.seek = { staleSeeks.append($0) }
inner.documentView!.addSubview(zeroInput)
let clippedContainer = ClippedInputContainer(frame: NSRect(x: 0,y: 0,width: 20,height: 20))
clippedContainer.wantsLayer = true
clippedContainer.layer?.masksToBounds = true
let clippedInput = GridSelectionView(frame: NSRect(x: 0,y: 0,width: 3_000,height: 1_600))
clippedInput.seek = { staleSeeks.append($0) }
clippedContainer.addSubview(clippedInput)
inner.documentView!.addSubview(clippedContainer)
let hiddenInput = GridSelectionView(frame: NSRect(x: 0,y: 0,width: 3_000,height: 1_600))
hiddenInput.seek = { staleSeeks.append($0) }; hiddenInput.isHidden = true
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
