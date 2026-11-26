import AppKit

// The view and modal gate below are extracted unchanged from production, apart
// from allowing this probe subclass and counting ancestry discoveries.
final class TrackMixerNativeControlView: NSView {
    let controls = NSHashTable<NSView>.weakObjects()
    func addControlArea(_ view: NSView) { controls.add(view) }
    func removeControlArea(_ view: NSView) { controls.remove(view) }
}
final class TrackSelectionRouter {
    static let shared = TrackSelectionRouter()
    func addControl(_ view: NSView) {}
}
enum CursorProbeCounts { static var discoveries = 0 }

// INSERT_PRODUCTION_CURSOR_VIEW

final class CursorProbe: TrackControlSelectionExclusionView {
    var registrations: [NSRect] = []
    override func addCursorRect(_ rect: NSRect, cursor: NSCursor) {
        precondition(cursor === NSCursor.arrow)
        registrations.append(rect)
    }
    func resetCount() -> Int { registrations.removeAll(); resetCursorRects(); return registrations.count }
}
final class CursorHost: NSView, NativeTimelineDefaultCursorHost {
    var suppliedCoverage: NSRect?
    override var visibleRect: NSRect { suppliedCoverage ?? super.visibleRect }
}
final class CursorWindow: NSWindow {
    var suppliedSheet: NSWindow?
    override var attachedSheet: NSWindow? { suppliedSheet ?? super.attachedSheet }
}
class CursorLayer<Content>: NSView {}

setbuf(stdout, nil)
_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
let baseline = CommandLine.arguments.contains("--baseline")
let window = CursorWindow(contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 500),
                          styleMask: [.titled], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
window.contentView = root
let host = CursorHost(frame: root.bounds)
root.addSubview(host)
let wrapper = NSView(frame: NSRect(x: 10, y: 10, width: 400, height: 300))
host.addSubview(wrapper)
let control = CursorProbe(frame: NSRect(x: 20, y: 20, width: 80, height: 24))
wrapper.addSubview(control)
precondition(control.resetCount() == 0, "Workspace supplies its descendant's default arrow")
let discoveries = CursorProbeCounts.discoveries
for _ in 0..<500 { precondition(control.resetCount() == 0) }
if !baseline {
    precondition(CursorProbeCounts.discoveries == discoveries, "Steady follow must reuse the discovered cursor ancestor")
}

// Moving a containing wrapper in the same window does not notify the control
// via viewDidMoveToSuperview. The cached old host must still be rejected.
root.addSubview(wrapper)
precondition(control.window === window && control.resetCount() == 1,
             "An old host elsewhere in the same window cannot suppress the local cursor")
let otherHost = CursorHost(frame: root.bounds)
root.addSubview(otherHost); otherHost.addSubview(wrapper)
precondition(control.resetCount() == 0, "Reparented controls discover their new workspace")
otherHost.suppliedCoverage = NSRect(x: 0, y: 0, width: 40, height: 500)
precondition(control.resetCount() == 1, "Partial host coverage keeps the control's own cursor")
otherHost.suppliedCoverage = nil
precondition(control.resetCount() == 0, "Restoring coverage enables sharing again")

otherHost.removeFromSuperview()
precondition(control.window == nil && control.resetCount() == 0, "Detached controls register no cursor")
root.addSubview(wrapper)
precondition(control.resetCount() == 1, "A detached host is not reused after the control moves back")
weak var removedHost: CursorHost?
autoreleasepool {
    let temporary = CursorHost(frame: root.bounds)
    removedHost = temporary; root.addSubview(temporary); temporary.addSubview(wrapper)
    precondition(control.resetCount() == 0)
    root.addSubview(wrapper); temporary.removeFromSuperview()
}
precondition(removedHost == nil, "The cached cursor host must not keep a closed workspace alive")
precondition(control.resetCount() == 1)

NativeTimelineInputGate.shared.setBlocked(true, for: window)
precondition(control.resetCount() == 0, "A modal input gate keeps its own cursor")
NativeTimelineInputGate.shared.setBlocked(false, for: window)
precondition(control.resetCount() == 1)
let sheet = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
sheet.isReleasedWhenClosed = false
window.suppliedSheet = sheet
precondition(control.resetCount() == 0, "An attached sheet keeps its own cursor")
window.suppliedSheet = nil
wrapper.isHidden = true
precondition(control.resetCount() == 0)
wrapper.isHidden = false
precondition(control.resetCount() == 1)
control.selectsTrack = true
precondition(control.hitTest(.zero) == nil && control.selectsTrack,
             "The passive control does not intercept selection or focus")
let mixer = TrackMixerNativeControlView(frame: root.bounds)
root.addSubview(mixer); mixer.addSubview(control)
precondition(mixer.controls.contains(control), "Native mixer selection registration remains intact")
root.addSubview(control)
precondition(!mixer.controls.contains(control), "Leaving a native mixer removes its selection registration")

// Approximate the deep generic hosting ancestry seen in the Intel sample.
let benchmarkHost = CursorHost(frame: root.bounds)
root.addSubview(benchmarkHost)
var parent: NSView = benchmarkHost
for index in 0..<40 {
    let layer: NSView = index.isMultiple(of: 2) ? CursorLayer<Int>(frame: root.bounds) : CursorLayer<String>(frame: root.bounds)
    parent.addSubview(layer); parent = layer
}
parent.addSubview(control); control.setFrameOrigin(NSPoint(x: 20, y: 20))
precondition(control.resetCount() == 0)
let before = CursorProbeCounts.discoveries
let start = CFAbsoluteTimeGetCurrent()
for _ in 0..<20_000 { control.resetCursorRects() }
let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
let searches = CursorProbeCounts.discoveries - before
if !baseline { precondition(searches == 0) }
print(String(format: "CURSOR_RESETS baseline=%@ count=20000 ms=%.3f discoveries=%d", baseline.description, elapsed, searches))
print("CURSOR_COVERAGE_REPARENT_DETACH_PARTIAL_GATE_SHEET_SELECTION_OK")
window.contentView = nil; window.close(); sheet.close()
