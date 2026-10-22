import Foundation

/// Pressing one item in a selection keeps the group available for a drag.
/// A plain click collapses that selection only when the pointer is released.
public struct TimelinePointerSelection: Equatable {
    public private(set) var items: Set<UUID> = []
    public private(set) var anchor: UUID?
    private var pressed: UUID?
    private var additive = false
    private var active = false
    public init() {}
    public mutating func replace(_ ids: Set<UUID>, anchor: UUID? = nil) {
        items = ids
        self.anchor = anchor.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
    }
    public mutating func begin(_ item: UUID?, additive: Bool) {
        pressed = item; self.additive = additive; active = true
        guard let item else { return }
        anchor = item
        if additive {
            if !items.insert(item).inserted {
                items.remove(item)
                anchor = items.first
            }
        } else if !items.contains(item) { items = [item] }
    }
    public mutating func beginDrag() {
        if let pressed { items.insert(pressed); anchor = pressed }
    }
    public mutating func end(dragged: Bool) {
        guard active else { return }
        if !dragged && !additive { replace(pressed.map { [$0] } ?? []) }
        pressed = nil; active = false
    }
    public mutating func retain(_ available: Set<UUID>) {
        replace(items.intersection(available), anchor: anchor)
    }
}
