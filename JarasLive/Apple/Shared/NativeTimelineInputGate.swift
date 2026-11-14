#if os(macOS)
import AppKit
import SwiftUI

@MainActor protocol NativeSidebarResizeViewportObserver: AnyObject {
    func sidebarResizeActivityChanged()
}

/// A divider moves fixed-size button groups through native parent frames.
/// Their SwiftUI roots need no second layout for that translation. Content or
/// local-size changes still lay out immediately; release flushes deferred work.
@MainActor final class NativeSidebarResizeActivity {
    static let shared = NativeSidebarResizeActivity()
    private weak var owner: NSView?
    private var retainsTimelineCoverage = false
    private let pending = NSHashTable<NSView>.weakObjects()
    private var observers: [NSObjectProtocol] = []
    private let viewportObservers = NSHashTable<NSView>.weakObjects()
    private(set) var contentRevision: UInt64 = 0
    private static let diagnose = ProcessInfo.processInfo.environment["CATLIVE_PROFILE_LAYOUT"] == "1"
    private var layoutReasons: [String: Int] = [:]
    private var reasonFlush: DispatchWorkItem?
    func recordLayout(_ role: String, view: NSView, sameBounds: Bool, sameContent: Bool) {
        guard Self.diagnose else { return }
        let active = owner?.window != nil && owner?.window === view.window
        let key = "\(role):active=\(active):bounds=\(sameBounds):content=\(sameContent)"
        layoutReasons[key, default: 0] += 1
        guard reasonFlush == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reasonFlush = nil
            let reasons = self.layoutReasons; self.layoutReasons.removeAll(keepingCapacity: true)
            if let data = try? JSONSerialization.data(withJSONObject: reasons, options: [.sortedKeys]),
               let line = String(data: data, encoding: .utf8) { NSLog("CATLIVE_RESIZE_LAYOUT %@", line) }
        }
        reasonFlush = work; DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
    func contentDidChange() { contentRevision &+= 1 }
    func canRetainTimelineCoverage(in window: NSWindow?) -> Bool {
        retainsTimelineCoverage && window != nil && owner?.window === window
    }
    func observeViewport(_ view: NSView & NativeSidebarResizeViewportObserver) { viewportObservers.add(view) }
    private func updateViewports() {
        for view in viewportObservers.allObjects { (view as? NativeSidebarResizeViewportObserver)?.sidebarResizeActivityChanged() }
    }
    func begin(owner: NSView, retainsTimelineCoverage: Bool = false) {
        finish()
        self.owner = owner
        self.retainsTimelineCoverage = retainsTimelineCoverage
        updateViewports()
        guard let window = owner.window else { return }
        for name in [NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish() }
            })
        }
    }
    func end(owner: NSView) { if self.owner === owner { finish() } }
    func deferUnchangedLayout(_ view: NSView) -> Bool {
        guard let window = owner?.window, view.window === window else { return false }
        pending.add(view)
        return true
    }
    private func finish() {
        owner = nil
        retainsTimelineCoverage = false
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        for view in pending.allObjects { view.needsLayout = true }
        pending.removeAllObjects()
        updateViewports()
    }
}

protocol TimelineGridKeyboardTarget: AnyObject {}

/// Native pointer monitors consume clicks before NSApplication/NSWindow can
/// activate the document. A Finder drop can leave a key-looking window in an
/// inactive application, so making only its first responder/key window is not
/// enough to restore editing shortcuts on Monterey/Ventura.
@MainActor enum NativeTimelineKeyboardFocus {
    @discardableResult static func activate(window: NSWindow?, responder: NSResponder?) -> Bool {
        guard let window, window.attachedSheet == nil, window.sheetParent == nil,
              NSApp.modalWindow == nil, !NativeTimelineInputGate.shared.isBlocked(window) else { return false }
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        return window.makeFirstResponder(responder)
    }
}

/// Keep adjacent input from building a visible backlog on slower Macs. Stop
/// before a key, mouse-up, changed target, direction or gesture boundary; those
/// events still go through their normal monitors and responder chain.
@MainActor enum NativeTimelineEventQueue {
    struct Wheel {
        var x: CGFloat
        var y: CGFloat
        var count = 1
    }
    private static func read(_ dequeue: Bool) -> NSEvent? {
        NSApp.nextEvent(matching: .any, until: .distantPast,
                        inMode: RunLoop.current.currentMode ?? .default, dequeue: dequeue)
    }
    static func latestDrag(_ event: NSEvent, read supplied: ((Bool) -> NSEvent?)? = nil) -> NSEvent {
        let read = supplied ?? Self.read
        var latest = event
        for _ in 0..<64 {
            guard let next = read(false), next.type == event.type,
                  next.window === event.window, next.buttonNumber == event.buttonNumber,
                  next.modifierFlags == event.modifierFlags,
                  next.timestamp >= latest.timestamp else { break }
            guard let consumed = read(true) else { break }
            latest = consumed
        }
        return latest
    }
    static func wheel(_ event: NSEvent, read supplied: ((Bool) -> NSEvent?)? = nil) -> Wheel {
        var result = Wheel(x: event.scrollingDeltaX, y: event.scrollingDeltaY)
        guard event.type == .scrollWheel, event.phase.intersection([.began, .ended, .cancelled]).isEmpty,
              event.momentumPhase.intersection([.began, .ended, .cancelled]).isEmpty else { return result }
        let read = supplied ?? Self.read
        var timestamp = event.timestamp
        for _ in 0..<64 {
            guard let next = read(false), next.type == .scrollWheel,
                  next.window === event.window, next.modifierFlags == event.modifierFlags,
                  next.hasPreciseScrollingDeltas == event.hasPreciseScrollingDeltas,
                  (abs(next.scrollingDeltaX) > abs(next.scrollingDeltaY)) == (abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)),
                  next.phase == event.phase, next.momentumPhase == event.momentumPhase,
                  next.timestamp >= timestamp,
                  abs(next.locationInWindow.x - event.locationInWindow.x) < 0.5,
                  abs(next.locationInWindow.y - event.locationInWindow.y) < 0.5,
                  next.scrollingDeltaX * result.x >= 0, next.scrollingDeltaY * result.y >= 0 else { break }
            guard let consumed = read(true) else { break }
            result.x += consumed.scrollingDeltaX; result.y += consumed.scrollingDeltaY
            result.count += 1; timestamp = consumed.timestamp
        }
        return result
    }
}

/// An ancestor that supplies an arrow over its visible bounds. Descendant
/// controls can share that default while keeping their own special cursors.
protocol NativeTimelineDefaultCursorHost: AnyObject {}

protocol NativeTimelineSelectionScrollHost: AnyObject {
    func prepareSelectionScroll(to origin: CGPoint, horizontal: Bool)
}

protocol NativeTimelineFollowPresentation: AnyObject {
    var isPlaybackFollowing: Bool { get }
}

/// Limit native mixer travel by event time, retaining ordinary small movements.
/// Excess flick distance is discarded immediately rather than replayed later.
struct NativeMixerScrollVelocity {
    private var lastTimestamp: TimeInterval?
    mutating func reset() { lastTimestamp = nil }
    // A smaller window must not require more gestures to reach the same track.
    // Native deltas are already expressed in points on both Retina and 1x Macs.
    static func maximum(viewport: CGFloat) -> CGFloat { 1800 }
    mutating func limit(_ delta: CGFloat, timestamp: TimeInterval, viewport: CGFloat, precise: Bool) -> CGFloat {
        guard delta.isFinite else { return 0 }
        guard timestamp.isFinite, timestamp > 0 else { reset(); return delta }
        let initial: TimeInterval = precise ? 1.0 / 60 : 1.0 / 30
        let elapsed: TimeInterval
        if let previous = lastTimestamp, timestamp >= previous, timestamp - previous <= 0.12 {
            // AppKit can deliver/coalesce input below 30 Hz while laying out a
            // busy window. Truncating that interval discards more travel on the
            // slower Mac. Use the event's full elapsed time, never processing
            // time, and retain the gesture-gap reset below.
            elapsed = timestamp - previous
        } else { elapsed = initial }
        lastTimestamp = timestamp
        let distance = Self.maximum(viewport: viewport) * elapsed
        return min(distance, max(-distance, delta))
    }
}

/// The outer workspace can resolve registered native controls before asking
/// SwiftUI to traverse every row for cursor tracking, selection or dividers.
class NativeWorkspaceHostingView<Content: View>: NSHostingView<Content>, NativeTimelineBodyInputHost {
    weak var timelineBodyInput: (NSView & NativeTimelineBodyInput)?
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHiddenOrHasHiddenAncestor, bounds.contains(local), visibleRect.contains(local) else { return nil }
        let location = convert(local, to: nil)
        if let target = NativeTimelineOverlayInputRegistration.hit(in: self, point: location) { return target }
        if let target = timelineBodyInput, target.window === window, target.isDescendant(of: self),
           let hit = target.hitTestTimelineBody(atWindowPoint: location) { return hit }
        if let hit = timelineControlHit(at: point) { return hit }
        return super.hitTest(point)
    }
}

/// Input covering the timeline body can answer directly. AppKit otherwise
/// traverses every nested hosting graph on cursor updates during zoom.
protocol NativeTimelineBodyInput: AnyObject {
    func hitTestTimelineBody(atWindowPoint point: NSPoint) -> NSView?
}
protocol NativeTimelineBodyInputHost: AnyObject {
    var timelineBodyInput: (NSView & NativeTimelineBodyInput)? { get set }
}

/// Interactive heads painted above the body retain their input before the
/// grid's selection monitor and fast native hit test claim the same point.
enum NativeTimelineOverlayInputRegistration {
    private static let views = NSHashTable<NSView>.weakObjects()
    private static let pinnedControls = NSHashTable<NSView>.weakObjects()
    static func add(_ view: NSView) { views.add(view) }
    static func addPinnedControls(_ view: NSView) { pinnedControls.add(view) }
    static func pinnedRoot(in host: NSView, point: NSPoint) -> NSView? {
        guard let window = host.window, window.attachedSheet == nil,
              !NativeTimelineInputGate.shared.isBlocked(window) else { return nil }
        return pinnedControls.allObjects.first { view in
            guard view.window === window, !view.isHiddenOrHasHiddenAncestor, view.isDescendant(of: host) else { return false }
            let local = view.convert(point, from: nil)
            return view.bounds.contains(local) && view.visibleRect.contains(local)
        }
    }
    static func hit(in host: NSView, point: NSPoint) -> NSView? {
        guard let window = host.window, window.attachedSheet == nil,
              !NativeTimelineInputGate.shared.isBlocked(window) else { return nil }
        // A vertically scrolled row remains geometrically underneath the
        // fixed mixer header. Its registered buttons/titles must not bypass
        // that visible header through the native fast path.
        if let pinned = pinnedRoot(in: host, point: point) {
            return pinned.hitTest(pinned.superview?.convert(point, from: nil) ?? point) ?? pinned
        }
        return views.allObjects.first { view in
            guard view.window === window, !view.isHiddenOrHasHiddenAncestor, view.isDescendant(of: host) else { return false }
            let local = view.convert(point, from: nil)
            return view.bounds.contains(local) && view.visibleRect.contains(local)
        }
    }
}

extension NativeTimelineBodyInputHost where Self: NSView {
    /// Only the visible body is owned by this shortcut. Header, sidebar,
    /// splitters, floating editors and blocked modal input follow AppKit.
    func timelineBodyHit(at point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHiddenOrHasHiddenAncestor, bounds.contains(local), visibleRect.contains(local),
              let target = timelineBodyInput, target.window === window,
              target.isDescendant(of: self) else { return nil }
        let location = convert(local, to: nil)
        if let marker = NativeTimelineOverlayInputRegistration.hit(in: self, point: location) { return marker }
        return target.hitTestTimelineBody(atWindowPoint: location)
    }
}

/// Rows register their retained native control hosts once, outside the cursor
/// path. Hit testing then visits only registered rows and each row's live bounds.
protocol NativeTimelineControlInput: AnyObject {
    func hitTestTimelineControl(atWindowPoint point: NSPoint) -> NSView?
}

@MainActor final class NativeTimelineControlInputRegistration {
    private static let inputs = NSMapTable<NSView, NSHashTable<NSView>>.weakToStrongObjects()
    private weak var input: (NSView & NativeTimelineControlInput)?
    private let hosts = NSHashTable<NSView>.weakObjects()
    init(_ input: NSView & NativeTimelineControlInput) { self.input = input }

    func update(active: Bool) {
        var next: [NSView] = []
        if active, let input, input.window != nil {
            var ancestor = input.superview
            while let view = ancestor {
                if view is NativeTimelineBodyInputHost { next.append(view) }
                ancestor = view.superview
            }
        }
        let previous = hosts.allObjects
        guard Set(previous.map(ObjectIdentifier.init)) != Set(next.map(ObjectIdentifier.init)), let input else { return }
        for host in previous { Self.inputs.object(forKey: host)?.remove(input) }
        hosts.removeAllObjects()
        for host in next {
            let rows = Self.inputs.object(forKey: host) ?? NSHashTable<NSView>.weakObjects()
            rows.add(input); Self.inputs.setObject(rows, forKey: host); hosts.add(host)
        }
    }

    static func hit(at point: NSPoint, in host: NSView,
                    mouseButtons: Int = NSEvent.pressedMouseButtons,
                    modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags,
                    eventType: NSEvent.EventType? = nil) -> NSView? {
        guard let window = host.window, !host.isHiddenOrHasHiddenAncestor,
              host.bounds.contains(point), host.visibleRect.contains(point),
              window.attachedSheet == nil, !NativeTimelineInputGate.shared.isBlocked(window),
              mouseButtons == 0, !modifiers.contains(.control),
              let rows = inputs.object(forKey: host) else { return nil }
        let location = host.convert(point, to: nil)
        var target: (NSView & NativeTimelineControlInput)?
        for row in rows.allObjects {
            guard row.window === window, !row.isHiddenOrHasHiddenAncestor,
                  row.isDescendant(of: host), let input = row as? (NSView & NativeTimelineControlInput) else { continue }
            let local = row.convert(location, from: nil)
            guard row.bounds.contains(local), row.visibleRect.contains(local) else { continue }
            // Even a front row's empty area can occlude a rear row's control.
            // Overlapping/reordering rows retain AppKit's normal z-order route.
            guard target == nil else { return nil }
            target = input
        }
        // Wheel input belongs to the enclosing scroll view (or the shared
        // row-height monitor), even over empty pixels. Ventura asks for its destination
        // again during each layout; walking nested SwiftUI hosts here spends
        // gesture on hover routing. Clicks keep their normal target.
        if (eventType ?? NSApp.currentEvent?.type) == .scrollWheel { return target }
        return target?.hitTestTimelineControl(atWindowPoint: location)
    }
}

extension NativeTimelineBodyInputHost where Self: NSView {
    /// Context clicks, drags, titles, resize handles and empty row space keep
    /// their ordinary responder route; only declared control areas participate.
    @MainActor func timelineControlHit(at point: NSPoint) -> NSView? {
        NativeTimelineControlInputRegistration.hit(at: convert(point, from: superview), in: self)
    }
}

protocol NativeTimelineInputObserver: AnyObject {
    var window: NSWindow? { get }
    func timelineInputGateChanged(blocked: Bool)
    func timelinePendingClickCancelled()
    func timelineActiveResizeCancelled() -> Bool
}
extension NativeTimelineInputObserver {
    func timelinePendingClickCancelled() {}
    func timelineActiveResizeCancelled() -> Bool { false }
}

/// AppKit input changes do not invalidate the nested SwiftUI timeline hosts.
/// Windows and observers are weak; another document remains interactive.
final class NativeTimelineInputGate {
    static let shared = NativeTimelineInputGate()
    private let blockedWindows = NSHashTable<NSWindow>.weakObjects()
    private final class Observer {
        weak var value: (any NativeTimelineInputObserver)?
        init(_ value: any NativeTimelineInputObserver) { self.value = value }
    }
    private var observers: [Observer] = []
    // Zoom can mount hundreds of region heads together. Identity lookup must
    // not scan all existing heads for every viewDidMoveToWindow callback.
    // Keep registration order for cancellation and weak ownership for closing.
    private let registered = NSHashTable<AnyObject>(options: [.weakMemory, .objectPointerPersonality])
    private var registrationsSinceCleanup = 0
    func isBlocked(_ window: NSWindow?) -> Bool {
        window.map { blockedWindows.contains($0) } ?? false
    }
    func add(_ observer: any NativeTimelineInputObserver) {
        if !registered.contains(observer) {
            registered.add(observer)
            observers.append(Observer(observer))
            registrationsSinceCleanup += 1
            if registrationsSinceCleanup >= 256 {
                observers.removeAll { $0.value == nil }
                registrationsSinceCleanup = 0
            }
        }
        observer.timelineInputGateChanged(blocked: isBlocked(observer.window))
    }
    /// Wheel panning owns the pending click, without blocking input or
    /// interrupting an item drag that has already begun.
    func cancelPendingClicks(for window: NSWindow) {
        observers.removeAll { $0.value == nil }
        for observer in observers {
            guard let value = observer.value, value.window === window else { continue }
            value.timelinePendingClickCancelled()
        }
    }
    @discardableResult func cancelActiveResize(for window: NSWindow?) -> Bool {
        guard let window else { return false }
        observers.removeAll { $0.value == nil }
        for observer in observers {
            guard let value = observer.value, value.window === window else { continue }
            if value.timelineActiveResizeCancelled() { return true }
        }
        return false
    }
    func setBlocked(_ blocked: Bool, for window: NSWindow) {
        guard blocked != blockedWindows.contains(window) else { return }
        if blocked { blockedWindows.add(window) } else { blockedWindows.remove(window) }
        observers.removeAll { $0.value == nil }
        for observer in observers {
            guard let value = observer.value, value.window === window else { continue }
            value.timelineInputGateChanged(blocked: blocked)
        }
    }
}

struct NativeTimelineModalGate: NSViewRepresentable {
    let blocked: Bool
    func makeNSView(context: Context) -> NativeTimelineModalGateView { NativeTimelineModalGateView() }
    func updateNSView(_ view: NativeTimelineModalGateView, context: Context) { view.blocked = blocked }
}
final class NativeTimelineModalGateView: NSView {
    var blocked = false {
        didSet { if let window { NativeTimelineInputGate.shared.setBlocked(blocked, for: window) } }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window, window !== newWindow { NativeTimelineInputGate.shared.setBlocked(false, for: window) }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { NativeTimelineInputGate.shared.setBlocked(blocked, for: window) }
    }
}
#endif
