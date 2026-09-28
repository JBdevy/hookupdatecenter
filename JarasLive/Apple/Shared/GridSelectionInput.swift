import SwiftUI

@MainActor final class TimelineAreaSelection: ObservableObject {
    struct Range: Equatable { let song: UUID; let start: Double; let end: Double }
    static let shared = TimelineAreaSelection()
    @Published private(set) var range: Range?
    func update(song: UUID, from: Double, to: Double) {
        guard from.isFinite, to.isFinite else { return }
        let start = max(0, min(from, to)), end = max(0, max(from, to))
        let next = end > start ? Range(song: song, start: start, end: end) : nil
        if range != next { range = next }
    }
    func clear() { if range != nil { range = nil } }
}

struct GridSelectionItem {
    let id: UUID
    let rect: CGRect
    var gain: Double = 1
    var editable = true
    var resizable = true
    var movable = true
    var contextActions = true
    var textEditable = false
    var muteRect: CGRect? { editable && rect.width >= 20 ? CGRect(x: rect.minX + 1, y: rect.minY, width: 17, height: 13) : nil }
    var fxRect: CGRect? { editable && rect.width >= 42 ? CGRect(x: rect.minX + 19, y: rect.minY, width: 20, height: 13) : nil }
    var gainKnobRect: CGRect? { editable && rect.width >= 64 ? CGRect(x: rect.minX + 40, y: rect.minY, width: 15, height: 13) : nil }
    var editRect: CGRect? { textEditable && rect.width >= 34 ? CGRect(x: rect.minX + 1, y: rect.minY, width: 30, height: 13) : nil }
    var titleInset: CGFloat { editRect != nil ? 33 : gainKnobRect != nil ? 56 : fxRect != nil ? 40 : muteRect != nil ? 19 : 2 }
    var gainPosition: Double { max(0, min(1, (20 * log10(max(0.000001, gain)) + 60) / 72)) }
    func draggingGain(by delta: CGFloat) -> Double {
        let position = max(0, min(1, gainPosition - Double(delta) / 120))
        return position == 0 ? 0 : pow(10, (position * 72 - 60) / 20)
    }
}
#if os(macOS)
import AppKit

struct GridSelectionInput: NSViewRepresentable {
    let origin: CGPoint
    let headerHeight: CGFloat
    let items: [GridSelectionItem]
    let selected: Set<UUID>
    let selectionChanged: (Set<UUID>) -> Void
    let mute: (UUID) -> Void
    let move: (UUID, CGSize, CGFloat, Bool) -> Void
    let seek: (CGFloat) -> Void
    let createRegion: (UUID) -> Void
    var interactionBlocked = false
    var resize: (UUID, Bool, CGFloat, Bool) -> Void = { _,_,_,_ in }
    var gain: (UUID, Double, Bool) -> Void = { _,_,_ in }
    var fx: (UUID, Bool) -> Void = { _, _ in }
    var editText: (UUID) -> Void = { _ in }
    var normalize: (Set<UUID>) -> Void = { _ in }
    var split: (Set<UUID>) -> Void = { _ in }
    func makeNSView(context: Context) -> GridSelectionView { GridSelectionView() }
    func updateNSView(_ view: GridSelectionView, context: Context) {
        view.timelineOrigin = origin; view.headerHeight = headerHeight
        view.interactionBlocked = interactionBlocked
        view.items = items; view.updateSelection(selected)
        view.mute = mute; view.move = move; view.seek = seek; view.selectionChanged = selectionChanged; view.createRegion = createRegion; view.normalize = normalize; view.split = split; view.resize = resize; view.gain = gain; view.fx = fx; view.editText = editText
    }
}
final class GridSelectionView: NSView, NativeTimelineInputObserver {
    var timelineOrigin = CGPoint.zero
    var headerHeight: CGFloat = 0
    var interactionBlocked = false { didSet { if interactionBlocked && !oldValue { timelineInputGateChanged(blocked: true) } } }
    var items: [GridSelectionItem] = []
    var selected = Set<UUID>()
    var selectionChanged: ((Set<UUID>) -> Void)?
    var createRegion: ((UUID) -> Void)?
    var resize: ((UUID, Bool, CGFloat, Bool) -> Void)?
    var gain: ((UUID, Double, Bool) -> Void)?
    var fx: ((UUID, Bool) -> Void)?
    var editText: ((UUID) -> Void)?
    private enum HeaderControl { case mute, fx, editText }
    private var pressedHeader: (id: UUID, rect: CGRect, control: HeaderControl)?
    private var headerPressCancelled = false
    private var resizingLeft: Bool?
    private var gainItem: GridSelectionItem?
    var normalize: ((Set<UUID>) -> Void)?
    var split: ((Set<UUID>) -> Void)?
    var mute: ((UUID) -> Void)?
    var move: ((UUID, CGSize, CGFloat, Bool) -> Void)?
    private var draggedItem: UUID?
    private var dragStart = CGPoint.zero
    private var dragOrigin = CGPoint.zero
    private var hasDragged = false
    private var movingAllowed = false
    var seek: ((CGFloat) -> Void)?
    private var anchor: CGPoint?
    private var selectionRect: CGRect?
    private var baseSelection = Set<UUID>()
    private var additive = false
    private var contextItem: UUID?
    private var pointerMonitor: Any?
    private var activeButton: Int?
    private var anchorInWindow = CGPoint.zero
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func updateSelection(_ next: Set<UUID>) {
        if anchor == nil { selected = next }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor); self.pointerMonitor = nil }
        activeButton = nil; anchor = nil; selectionRect = nil; draggedItem = nil; hasDragged = false
        pressedHeader = nil; headerPressCancelled = false
        guard window != nil else { return }
        NativeTimelineInputGate.shared.add(self)
        pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseDragged, .rightMouseUp]) { [weak self] event in
            self?.handlePointerEvent(event) == true ? nil : event
        }
    }
    deinit { if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) } }
    // Use native scroll bounds, not the delayed SwiftUI offset from its last render.
    private var coordinates: (viewport: CGRect, origin: CGPoint) {
        var scrolls: [NSScrollView] = []
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? NSScrollView { scrolls.append(scroll) }
            ancestor = view.superview
        }
        guard let horizontal = scrolls.first, let vertical = scrolls.last, horizontal !== vertical else { return (bounds, timelineOrigin) }
        let viewport = convert(horizontal.contentView.bounds, from: horizontal.contentView)
            .intersection(convert(vertical.contentView.bounds, from: vertical.contentView))
        return (viewport, CGPoint(x: horizontal.contentView.bounds.minX, y: vertical.contentView.bounds.minY))
    }
    private func timelinePoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let space = coordinates
        return CGPoint(x: point.x - space.viewport.minX + space.origin.x, y: point.y - space.viewport.minY + space.origin.y)
    }
    @discardableResult func handlePointerEvent(_ event: NSEvent) -> Bool {
        guard !interactionBlocked, !NativeTimelineInputGate.shared.isBlocked(window), event.window === window, window != nil, window?.attachedSheet == nil,
              !isHiddenOrHasHiddenAncestor else { return false }
        let down = event.type == .leftMouseDown || event.type == .rightMouseDown
        if down {
            let point = convert(event.locationInWindow, from: nil)
            let viewport = coordinates.viewport
            // Hosting can keep an obsolete input view attached during layout.
            // Its monitor must never intercept a click outside its visible area.
            guard bounds.contains(point), visibleRect.contains(point),
                  viewport.contains(point), point.y >= viewport.minY + headerHeight else { return false }
            activeButton = event.buttonNumber
        } else if activeButton != event.buttonNumber { return false }
        switch event.type {
        case .leftMouseDown: mouseDown(with: event)
        case .leftMouseDragged: mouseDragged(with: event)
        case .leftMouseUp: activeButton = nil; mouseUp(with: event)
        case .rightMouseDown: rightMouseDown(with: event)
        case .rightMouseDragged: rightMouseDragged(with: event)
        case .rightMouseUp: activeButton = nil; rightMouseUp(with: event)
        default: return false
        }
        return true
    }
    func timelineInputGateChanged(blocked: Bool) {
        guard blocked else { return }
        // A modal opened during a press must not leave a latent mouse-up action.
        activeButton = nil; anchor = nil; selectionRect = nil; contextItem = nil
        draggedItem = nil; hasDragged = false; movingAllowed = false
        pressedHeader = nil; headerPressCancelled = false; gainItem = nil; resizingLeft = nil
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        let timeline = timelinePoint(event)
        draggedItem = nil; hasDragged = false; movingAllowed = false; resizingLeft = nil; gainItem = nil
        pressedHeader = nil; headerPressCancelled = false
        guard let item = items.first(where: { $0.rect.contains(timeline) }) else { seek?(timeline.x); return }
        if let rect = item.editRect, rect.contains(timeline) {
            pressedHeader = (item.id, rect, .editText); dragStart = event.locationInWindow; return
        } else if item.gainKnobRect?.contains(timeline) == true {
            if event.clickCount == 2 { gain?(item.id, 1, true); return }
            gainItem = item; draggedItem = item.id; dragStart = event.locationInWindow; return
        } else if let rect = item.fxRect, rect.contains(timeline) {
            pressedHeader = (item.id, rect, .fx); dragStart = event.locationInWindow; return
        } else if let rect = item.muteRect, rect.contains(timeline) {
            pressedHeader = (item.id, rect, .mute); dragStart = event.locationInWindow; return
        } else if item.resizable && item.rect.width > 14 && (timeline.x < item.rect.minX + 5 || timeline.x > item.rect.maxX - 5) {
            resizingLeft = timeline.x < item.rect.midX
        }
        let additive = !event.modifierFlags.intersection([.command, .control]).isEmpty
        if additive {
            if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
        } else { selected = [item.id] }
        selectionChanged?(selected)
        movingAllowed = item.movable
        draggedItem = item.id; dragStart = event.locationInWindow; dragOrigin = timeline
    }
    override func mouseDragged(with event: NSEvent) {
        if pressedHeader != nil {
            if hypot(event.locationInWindow.x - dragStart.x, event.locationInWindow.y - dragStart.y) >= 3 {
                headerPressCancelled = true
            }
            return
        }
        guard let id = draggedItem else { return }
        let translation = CGSize(width: event.locationInWindow.x - dragStart.x, height: dragStart.y - event.locationInWindow.y)
        guard hasDragged || hypot(translation.width, translation.height) >= 3 else { return }
        hasDragged = true
        if let resizingLeft { resize?(id, resizingLeft, translation.width, false) }
        else if let gainItem { gain?(id, gainItem.draggingGain(by: translation.height), false) }
        else if movingAllowed { move?(id, translation, dragOrigin.y + translation.height, false) }
    }
    override func mouseUp(with event: NSEvent) {
        if let header = pressedHeader {
            pressedHeader = nil
            let activate = !headerPressCancelled && header.rect.contains(timelinePoint(event)) && items.contains { $0.id == header.id && (header.control == .editText ? $0.textEditable : $0.editable) }
            headerPressCancelled = false
            // The native monitor consumes this mouse-up. A sheet opened here
            // cannot receive the release that activated its originating FX button.
            if activate {
                switch header.control {
                case .mute: mute?(header.id)
                case .fx: fx?(header.id, event.modifierFlags.contains(.option))
                case .editText: editText?(header.id)
                }
            }
            return
        }
        if let id = draggedItem, hasDragged {
            let translation = CGSize(width: event.locationInWindow.x - dragStart.x, height: dragStart.y - event.locationInWindow.y)
            if let resizingLeft { resize?(id, resizingLeft, translation.width, true) }
            else if let gainItem { gain?(id, gainItem.draggingGain(by: translation.height), true) }
            else if movingAllowed { move?(id, translation, dragOrigin.y + translation.height, true) }
        }
        draggedItem = nil; hasDragged = false; movingAllowed = false
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        guard !interactionBlocked, !NativeTimelineInputGate.shared.isBlocked(window) else { return }
        let point = timelinePoint(event)
        guard let item = items.first(where: { $0.rect.contains(point) }) else { NSCursor.arrow.set(); return }
        if item.gainKnobRect?.contains(point) == true { NSCursor.resizeUpDown.set() }
        else if item.fxRect?.contains(point) == true || item.muteRect?.contains(point) == true || item.editRect?.contains(point) == true { NSCursor.pointingHand.set() }
        else if item.resizable && item.rect.width > 14 && (point.x < item.rect.minX + 5 || point.x > item.rect.maxX - 5) { NSCursor.resizeLeftRight.set() }
        else { NSCursor.arrow.set() }
    }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
    override func rightMouseDown(with event: NSEvent) {
        anchor = timelinePoint(event)
        anchorInWindow = event.locationInWindow
        additive = !event.modifierFlags.intersection([.shift, .command, .control]).isEmpty
        baseSelection = additive ? selected : []
        selectionRect = nil
    }
    override func rightMouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let point = timelinePoint(event)
        guard selectionRect != nil || hypot(event.locationInWindow.x-anchorInWindow.x, event.locationInWindow.y-anchorInWindow.y) >= 3 else { return }
        let top = max(coordinates.origin.y + headerHeight, min(anchor.y, point.y))
        let rect = CGRect(x: min(anchor.x,point.x), y: top, width: max(1,abs(point.x-anchor.x)), height: max(1,max(anchor.y,point.y)-top))
        selectionRect = rect
        let next = baseSelection.union(items.lazy.filter { $0.rect.intersects(rect) }.map(\.id))
        if selected != next { selected = next; selectionChanged?(next) }
        needsDisplay = true
    }
    override func rightMouseUp(with event: NSEvent) {
        guard let anchor else { return }
        rightMouseDragged(with: event)
        if selectionRect == nil {
            contextItem = items.first { $0.rect.contains(anchor) }?.id
            if let contextItem {
                if !selected.contains(contextItem) { selected = [contextItem]; selectionChanged?(selected) }
                guard items.first(where: { $0.id == contextItem })?.contextActions == true else {
                    self.anchor = nil; selectionRect = nil; needsDisplay = true
                    return
                }
                let menu = NSMenu()
                let item = NSMenuItem(title: JarasLocalization.string("Criar região do item"), action: #selector(createContextRegion), keyEquivalent: "")
                item.target = self; menu.addItem(item)
                let normalize = NSMenuItem(title: JarasLocalization.string("Normalize…"), action: #selector(normalizeSelection), keyEquivalent: "")
                normalize.target = self; menu.addItem(normalize)
                let split = NSMenuItem(title: JarasLocalization.string("Split at edit cursor…"), action: #selector(splitSelection), keyEquivalent: "")
                split.target = self; menu.addItem(split)
                NSMenu.popUpContextMenu(menu, with: event, for: self)
            } else if !additive { selected.removeAll(); selectionChanged?([]) }
        }
        self.anchor = nil; selectionRect = nil; needsDisplay = true
    }
    @objc private func normalizeSelection() { normalize?(selected) }
    @objc private func splitSelection() { split?(selected) }
    @objc private func createContextRegion() { if let contextItem { createRegion?(contextItem) } }
    override func draw(_ dirtyRect: NSRect) {
        guard let timelineRect = selectionRect else { return }
        let space = coordinates
        let rect = timelineRect.offsetBy(dx: space.viewport.minX - space.origin.x, dy: space.viewport.minY - space.origin.y)
        NSColor.systemGreen.withAlphaComponent(0.12).setFill()
        NSBezierPath(rect: rect).fill()
        NSColor.systemGreen.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)); border.lineWidth = 1; border.stroke()
    }
}
#endif
