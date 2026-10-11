import AppKit
import SwiftUI
@MainActor final class ShowController {
    var current: Song? = Project.empty(name: "Env input").songs[0]
    var settings = TrackAutomation()
    var commits = 0
    func automation(_ track: UUID?) -> TrackAutomation { settings }
    func setAutomation(_ track: UUID?, settings: TrackAutomation) { self.settings = settings; commits += 1 }
}
@MainActor func run() {
let app = NSApplication.shared
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
let view = AutomationLaneView(); window.contentView = view; window.makeKeyAndOrderFront(nil)
let show = ShowController()
let envelope = TrackEnvelope(target: AutomationTarget(.pan), name: "Pan", defaultValue: 0.5)
show.settings.envelopes = [envelope]
view.configure(show: show, entries: [.init(track: nil, envelope: envelope, y: 200, height: 140)], minimumY: 0)
view.project(viewport: CGRect(x: 100, y: 200, width: 600, height: 160), scale: 100, movesFrame: false)
func mouse(_ type: NSEvent.EventType, x: Double, y: Double, clicks: Int = 1, shift: Bool = true) -> NSEvent {
    let location = view.convert(NSPoint(x: x, y: y), to: nil)
    return NSEvent.mouseEvent(with: type, location: location, modifierFlags: shift ? [.shift] : [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
}
precondition(view.hit(atWindowPoint: view.convert(NSPoint(x: 10,y: 80),to:nil)) === view)
view.mouseDown(with: mouse(.leftMouseDown,x: 77,y: 78,clicks: 2))
precondition(show.settings.envelopes[0].points.count == 1)
var point = show.settings.envelopes[0].points[0]
precondition(abs(point.time-1.77)<1e-8 && abs(point.value-0.5)<1e-8, "Viewport translation and free insertion")
view.mouseDown(with: mouse(.leftMouseDown,x: 77,y: 78))
view.mouseDragged(with: mouse(.leftMouseDragged,x: 109,y: 51))
view.mouseUp(with: mouse(.leftMouseUp,x: 109,y: 51))
point = show.settings.envelopes[0].points[0]
precondition(abs(point.time-2.09)<1e-8 && abs(point.value-0.75)<1e-8, "Point drag preserves time/value under scroll")
let menu = view.menu(for: mouse(.rightMouseDown,x: 109,y: 51))!
let shape = menu.items[2]
app.sendAction(shape.action!,to:shape.target,from:shape)
precondition(show.settings.envelopes[0].points[0].shape == .smooth)
view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 51)!)
precondition(show.settings.envelopes[0].points.isEmpty)
view.mouseDown(with: mouse(.leftMouseDown,x: 79,y: 78,clicks: 2,shift: false))
precondition(show.settings.envelopes[0].points[0].time != 1.79, "Normal insertion snaps to musical grid")
print("AUTOMATION_NATIVE_ADD_DRAG_DELETE_CURVES_SCROLL_SNAP_OK")

// Inline lanes share the scrolled timeline with a pinned ruler and audio rows.
// Coordinate translation must identify the lane before editing any parameter.
window.setContentSize(NSSize(width: 600, height: 340))
view.setFrameSize(NSSize(width: 600, height: 340))
show.settings.envelopes = [
    TrackEnvelope(target: AutomationTarget(.pan), name: "Pan", defaultValue: 0.5),
    TrackEnvelope(target: AutomationTarget(.volume), name: "Volume", defaultValue: 0.5)
]
func entries(_ indices: [Int] = [0, 1]) -> [AutomationLaneView.Entry] {
    indices.map { index in
        .init(track: nil, envelope: show.settings.envelopes[index], y: index == 0 ? 200 : 360, height: 140)
    }
}
func hit(_ x: Double, _ y: Double) -> NSView? {
    view.hit(atWindowPoint: view.convert(NSPoint(x: x, y: y), to: nil))
}
func key(_ code: UInt16) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
        windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: code)!
}
view.configure(show: show, entries: entries(), minimumY: 48)
view.project(viewport: CGRect(x: 300, y: 200, width: 600, height: 340), scale: 100, movesFrame: false)
precondition(hit(40, 47) == nil && hit(40, 48) === view, "pinned ruler keeps its hit area while a lane scrolls behind it")
precondition(hit(40, 150) == nil && hit(40, 238) === view && hit(40, 330) == nil, "audio gaps and empty timeline remain outside envelope input")
precondition(hit(-1, 238) == nil && hit(601, 238) == nil, "lane hit testing stays inside the visible viewport")
view.mouseDown(with: mouse(.leftMouseDown, x: 77, y: 78, clicks: 2))
view.mouseDown(with: mouse(.leftMouseDown, x: 121, y: 238, clicks: 2))
precondition(window.firstResponder === view && window.firstResponder is any TimelineGridKeyboardTarget)
precondition(show.settings.envelopes.allSatisfy { $0.points.count == 1 })
let upperPoint = show.settings.envelopes[0].points[0]
let lowerPoint = show.settings.envelopes[1].points[0]
precondition(abs(upperPoint.time - 3.77) < 1e-8 && abs(lowerPoint.time - 4.21) < 1e-8)
precondition(abs(upperPoint.value - 0.5) < 1e-8 && abs(lowerPoint.value - 0.5) < 1e-8,
    "each envelope uses its own vertical origin at nonzero horizontal and vertical scroll")

let beforeCancel = show.settings, commitsBeforeCancel = show.commits
view.mouseDown(with: mouse(.leftMouseDown, x: 121, y: 238))
view.mouseDragged(with: mouse(.leftMouseDragged, x: 168, y: 211))
view.keyDown(with: key(53))
view.mouseUp(with: mouse(.leftMouseUp, x: 168, y: 211))
precondition(show.settings == beforeCancel && show.commits == commitsBeforeCancel,
    "Escape rolls back a point drag without saving any transient change")
view.mouseDown(with: mouse(.leftMouseDown, x: 121, y: 238))
view.mouseDragged(with: mouse(.leftMouseDragged, x: 143, y: 211))
view.mouseUp(with: mouse(.leftMouseUp, x: 143, y: 211))
precondition(show.settings.envelopes[0].points == [upperPoint], "editing lower lane never changes upper lane")
precondition(abs(show.settings.envelopes[1].points[0].time - 4.43) < 1e-8 &&
    abs(show.settings.envelopes[1].points[0].value - 0.75) < 1e-8,
    "after Escape the original visual point remains draggable")
view.keyDown(with: key(53))
view.keyDown(with: key(117))
precondition(show.settings.envelopes[1].points.count == 1, "Escape with no active drag clears point selection")
print("AUTOMATION_INLINE_TWO_LANES_SCROLLED_COORDINATES_PINNED_RULER_ESCAPE_ROLLBACK_OK")

// Hiding and reopening lanes must preserve automation but cannot carry an old
// invisible point selection into a later Delete command.
view.mouseDown(with: mouse(.leftMouseDown, x: 143, y: 211))
view.mouseUp(with: mouse(.leftMouseUp, x: 143, y: 211))
let beforeHidden = show.settings
view.configure(show: show, entries: [], minimumY: 48)
precondition(view.isHidden && hit(143, 211) == nil)
view.configure(show: show, entries: entries(), minimumY: 48)
precondition(!view.isHidden && show.settings == beforeHidden)
view.keyDown(with: key(51))
precondition(show.settings == beforeHidden, "showing a lane again must not resurrect its stale hidden point selection")
view.mouseDown(with: mouse(.leftMouseDown, x: 143, y: 211))
view.mouseUp(with: mouse(.leftMouseUp, x: 143, y: 211))
view.configure(show: show, entries: entries([0]), minimumY: 48)
view.keyDown(with: key(51))
precondition(show.settings == beforeHidden, "hiding one envelope cannot delete points in another visible envelope")
view.configure(show: show, entries: entries(), minimumY: 48)
view.mouseDown(with: mouse(.leftMouseDown, x: 143, y: 211))
view.mouseDragged(with: mouse(.leftMouseDragged, x: 165, y: 200))
let commitsBeforeHideDrag = show.commits
view.configure(show: show, entries: entries([0]), minimumY: 48)
view.mouseUp(with: mouse(.leftMouseUp, x: 165, y: 200))
precondition(show.settings == beforeHidden && show.commits == commitsBeforeHideDrag,
    "hiding a dragged envelope cancels the gesture before its old index can edit another lane")
print("AUTOMATION_INLINE_HIDE_SHOW_PRESERVES_POINTS_CLEARS_STALE_SELECTION_OK")

// The inline lane follows one third of its track's height. Compact lanes have
// no embedded title band; the complete value range stays inside their bounds.
let compactCases: [(height: Double, center: Double, top: Double, bottom: Double,
                    resizedHeight: Double, resizedCenter: Double, resizedBottom: Double)] = [
    (20, 90, 85, 95, 32, 96, 106),
    (32, 96, 86, 106, 8, 84, 86),
    (8, 84, 82, 86, 20, 90, 95),
    (64.0 / 3, 80 + 32.0 / 3, 80 + 16.0 / 3, 96, 32, 96, 106)
]
for example in compactCases {
    show.settings.envelopes = [TrackEnvelope(target: AutomationTarget(.pan), name: "Pan", defaultValue: 0.5)]
    view.configure(show: show, entries: [.init(track: nil, envelope: show.settings.envelopes[0], y: 280, height: example.height)], minimumY: 48)
    view.project(viewport: CGRect(x: 300, y: 200, width: 600, height: 340), scale: 100, movesFrame: false)
    precondition(hit(150, example.center) === view && hit(150, 80 + example.height) == nil)
    view.mouseDown(with: mouse(.leftMouseDown, x: 150, y: example.center, clicks: 2))
    precondition(show.settings.envelopes[0].points.count == 1)
    precondition(abs(show.settings.envelopes[0].points[0].time - 4.5) < 1e-8 &&
        abs(show.settings.envelopes[0].points[0].value - 0.5) < 1e-8,
        "the middle of a compact lane represents the middle value")
    view.mouseDown(with: mouse(.leftMouseDown, x: 150, y: example.center))
    view.mouseDragged(with: mouse(.leftMouseDragged, x: 180, y: example.top))
    view.mouseUp(with: mouse(.leftMouseUp, x: 180, y: example.top))
    precondition(abs(show.settings.envelopes[0].points[0].value - 1) < 1e-8,
        "compact lanes expose their maximum without using another track's space")
    view.mouseDown(with: mouse(.leftMouseDown, x: 180, y: example.top))
    view.mouseDragged(with: mouse(.leftMouseDragged, x: 220, y: example.bottom))
    view.mouseUp(with: mouse(.leftMouseUp, x: 220, y: example.bottom))
    precondition(abs(show.settings.envelopes[0].points[0].time - 5.2) < 1e-8 &&
        abs(show.settings.envelopes[0].points[0].value) < 1e-8,
        "even an eight-point lane can edit the entire value range")
    let beforeResize = show.settings
    view.configure(show: show, entries: [.init(track: nil, envelope: show.settings.envelopes[0], y: 320, height: example.resizedHeight)], minimumY: 48)
    view.project(viewport: CGRect(x: 450, y: 240, width: 600, height: 340), scale: 125, movesFrame: false)
    precondition(show.settings == beforeResize, "resizing and reprojecting only changes display geometry")
    view.mouseDown(with: mouse(.leftMouseDown, x: 200, y: example.resizedBottom))
    view.mouseDragged(with: mouse(.leftMouseDragged, x: 225, y: example.resizedCenter))
    view.mouseUp(with: mouse(.leftMouseUp, x: 225, y: example.resizedCenter))
    precondition(abs(show.settings.envelopes[0].points[0].time - 5.4) < 1e-8 &&
        abs(show.settings.envelopes[0].points[0].value - 0.5) < 1e-8,
        "point hit testing and value editing use the same geometry after track resize and zoom")
}
print("AUTOMATION_COMPACT_LANES_8_20_32_AND_TRACK_THIRD_HEIGHT_FULL_RANGE_RESIZE_PROJECTION_OK")

}
MainActor.assumeIsolated { run() }
