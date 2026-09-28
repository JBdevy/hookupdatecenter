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
    @discardableResult func handle(_ event: NSEvent) -> Bool {
        let optionClick = event.type == .leftMouseDown && event.modifierFlags.contains(.option) && !event.modifierFlags.contains(.control)
        guard !interactionBlocked, event.type == .rightMouseDown || event.modifierFlags.contains(.control) || optionClick,
              let window = event.window, window.attachedSheet == nil else { return false }
        let match = targets.allObjects.filter {
            (!optionClick || $0.optionClick != nil) && !$0.interactionBlocked && $0.window === window && !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 0 && $0.bounds.height > 0 && $0.bounds.contains($0.convert(event.locationInWindow,from: nil)) && $0.visibleRect.contains($0.convert(event.locationInWindow,from: nil))
        }.sorted {
            $0.priority == $1.priority ? $0.bounds.width*$0.bounds.height < $1.bounds.width*$1.bounds.height : $0.priority > $1.priority
        }.first
        guard let match else { return false }
        (optionClick ? match.optionClick : match.action)?()
        return true
    }
}
class RightClickTargetView: NSView {
    var interactionBlocked = false
    var action: (() -> Void)?
    var optionClick: (() -> Void)?
    var priority: Int { 0 }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { RightClickRouter.shared.add(self) } }
}
#endif
