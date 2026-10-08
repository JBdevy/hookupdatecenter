#if os(macOS)
import AppKit
/// One event monitor resolves overlapping regions by priority; a track's fallback
/// never steals a right-click from its M/S/REC controls.
@MainActor final class RightClickRouter {
    static let shared = RightClickRouter()
    private let targets = NSHashTable<RightClickTargetView>.weakObjects()
    private var monitor: Any?
    var interactionBlocked = false
    func add(_ target: RightClickTargetView) {
        targets.add(target)
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown,.leftMouseDown]) { [weak self] event in
                self?.handle(event) == true ? nil : event
            }
        }
    }
    func handlesModifiedLeftClick(_ event: NSEvent) -> Bool {
        event.type == .leftMouseDown && !event.modifierFlags.intersection([.option, .shift]).isEmpty && target(for: event) != nil
    }
    private func target(for event: NSEvent) -> RightClickTargetView? {
        let optionClick = event.type == .leftMouseDown && event.modifierFlags.contains(.option) && !event.modifierFlags.contains(.control)
        let shiftClick = event.type == .leftMouseDown && event.modifierFlags.contains(.shift) && !event.modifierFlags.contains(.control) && !optionClick
        guard !interactionBlocked, event.type == .rightMouseDown || event.modifierFlags.contains(.control) || optionClick || shiftClick,
              let window = event.window, window.attachedSheet == nil else { return nil }
        return targets.allObjects.filter {
            (!optionClick || $0.optionClick != nil) && (!shiftClick || $0.shiftClick != nil) && !$0.interactionBlocked && $0.window === window && !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 0 && $0.bounds.height > 0 && $0.clickBounds.contains($0.convert(event.locationInWindow,from: nil)) && $0.visibleRect.contains($0.convert(event.locationInWindow,from: nil))
        }.sorted {
            $0.priority == $1.priority ? $0.clickPriorityArea < $1.clickPriorityArea : $0.priority > $1.priority
        }.first
    }
    @discardableResult func handle(_ event: NSEvent) -> Bool {
        guard let match = target(for: event) else { return false }
        if event.type == .leftMouseDown && !event.modifierFlags.contains(.control) {
            if event.modifierFlags.contains(.option) { match.optionClick?(); return true }
            if event.modifierFlags.contains(.shift) { match.shiftClick?(); return true }
        }
        match.action?(); return true
    }

}
class RightClickTargetView: NSView {
    var interactionBlocked = false
    var action: (() -> Void)?
    var optionClick: (() -> Void)?
    var shiftClick: (() -> Void)?
    var priority: Int { 0 }
    var clickBounds: NSRect { bounds }
    var clickPriorityArea: CGFloat { bounds.width * bounds.height }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { RightClickRouter.shared.add(self) } }
}
#endif
