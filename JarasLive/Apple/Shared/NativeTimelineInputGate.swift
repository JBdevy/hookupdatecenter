#if os(macOS)
import AppKit
import SwiftUI

protocol TimelineGridKeyboardTarget: AnyObject {}

/// An ancestor that supplies an arrow over its visible bounds. Descendant
/// controls can share that default while keeping their own special cursors.
protocol NativeTimelineDefaultCursorHost: AnyObject {}

/// Input covering the timeline body can answer directly. AppKit otherwise
/// traverses every nested hosting graph on cursor updates during zoom.
protocol NativeTimelineBodyInput: AnyObject {
    func hitTestTimelineBody(atWindowPoint point: NSPoint) -> NSView?
}
protocol NativeTimelineBodyInputHost: AnyObject {
    var timelineBodyInput: (NSView & NativeTimelineBodyInput)? { get set }
}

extension NativeTimelineBodyInputHost where Self: NSView {
    /// Only the visible body is owned by this shortcut. Header, sidebar,
    /// splitters, floating editors and blocked modal input follow AppKit.
    func timelineBodyHit(at point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !isHiddenOrHasHiddenAncestor, bounds.contains(local), visibleRect.contains(local),
              let target = timelineBodyInput, target.window === window,
              target.isDescendant(of: self) else { return nil }
        return target.hitTestTimelineBody(atWindowPoint: convert(local, to: nil))
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
                    modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) -> NSView? {
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
    func isBlocked(_ window: NSWindow?) -> Bool {
        window.map { blockedWindows.contains($0) } ?? false
    }
    func add(_ observer: any NativeTimelineInputObserver) {
        observers.removeAll { $0.value == nil }
        if !observers.contains(where: { $0.value === observer }) { observers.append(Observer(observer)) }
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
