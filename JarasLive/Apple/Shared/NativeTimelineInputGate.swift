#if os(macOS)
import AppKit
import SwiftUI

protocol NativeTimelineInputObserver: AnyObject {
    var window: NSWindow? { get }
    func timelineInputGateChanged(blocked: Bool)
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
