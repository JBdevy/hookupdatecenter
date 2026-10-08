private enum RegionPoolProbe {
    static var created = 0
    static var treeChanges = 0
    static var menuBody: ((RegionRightClickView, NSMenu) -> Void)?
}

@MainActor private func runPoolTests() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let root = NSView(frame: window.contentView!.bounds)
    window.contentView = root
    let host = NativeTimelineRegionTargetsView(frame: CGRect(x: 0, y: 0, width: 1_000_000, height: 100))
    root.addSubview(host)
    defer { window.close() }
    let viewport = CGRect(x: 0, y: 0, width: 700, height: 100)
    var edits: [UUID] = [], seeks: [UUID] = [], dragEvents: [(UUID, CGFloat, Bool)] = []
    func target(_ id: UUID = UUID(), at x: Double, duration: Double = 10, selected: Bool = false) -> NativeTimelineRegionTarget {
        let input = RegionRightClick(edit: { edits.append(id) }, delete: { edits.append(id) }, seek: { seeks.append(id) },
            drag: { delta, ended, _ in dragEvents.append((id, delta, ended)) })
        return NativeTimelineRegionTarget(id: id, start: x, end: x + duration, lane: 0, edgePadding: 0,
            selected: selected, pinned: false, input: input)
    }
    func project(_ x: CGFloat = 0) { host.project(scale: 1, viewport: viewport.offsetBy(dx: x, dy: 0)) }
    func event(_ type: NSEvent.EventType, x: CGFloat, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: host.convert(CGPoint(x: x, y: 8), to: nil), modifierFlags: flags,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    func assertIdle(_ views: [RegionRightClickView]) {
        for view in views {
            precondition(view.projectedInputBounds.isEmpty && !view.isHidden && view.wantsUpdateLayer)
            precondition(view.edit == nil && view.detectBPM == nil && view.unify == nil && view.disunify == nil &&
                view.delete == nil && view.drag == nil && view.seek == nil && view.projectedInteractionEnded == nil,
                "inactive slots must release all old project commands")
            view.updateTrackingAreas(); view.updateLayer()
            precondition(view.trackingAreas.isEmpty && view.layer?.contents == nil, "no per-slot tracking or bitmap backing")
            precondition((view.layer?.sublayers ?? []).allSatisfy { layer in
                guard let shape = layer as? CAShapeLayer else { return layer.contents == nil }
                return shape.isHidden && shape.path == nil && shape.contents == nil
            }, "inactive grip/selection have no visible ink or retained path")
        }
    }
    let groups: [NativeTimelineRegionTarget] = (0..<48).map { index in
        let groupX = Double(index / 12) * 10000
        let itemX = 100 + Double(index % 12) * 20
        return target(at: groupX + itemX, selected: index % 12 == 0)
    }
    host.configure(groups); project()
    let identities = Set(host.subviews.map(ObjectIdentifier.init))
    let created = RegionPoolProbe.created, mutations = RegionPoolProbe.treeChanges
    for frame in 0..<160 {
        project(CGFloat(frame % 4) * 10000)
        precondition(host.activeForTest.count == 12 && host.idleForTest.isEmpty)
        precondition(Set(host.subviews.map(ObjectIdentifier.init)) == identities)
        precondition(host.subviews.allSatisfy { $0.frame == host.bounds && !$0.isHidden && $0.layer?.contents == nil })
    }
    precondition(RegionPoolProbe.created == created && RegionPoolProbe.treeChanges == mutations,
        "warm zoom/culling must reuse the same mounted tree without allocations or add/remove")
    project(900000)
    precondition(host.activeForTest.isEmpty && host.idleForTest.count == 12 && host.subviews.count == 12)
    assertIdle(host.idleForTest)
    precondition(host.hitTest(CGPoint(x: 120, y: 8)) == nil, "pooled views cannot steal an old target's click")
    print("REGION_POOL_WARM_160_FRAMES_ZERO_REMOUNT_NO_HIDDEN_NO_RASTER_OK")

    // The same slot can safely serve entirely new structural IDs.
    let replacement = target(at: 100, duration: 400)
    host.configure([replacement]); project()
    let replacementView = host.activeForTest[replacement.id]!
    precondition(identities.contains(ObjectIdentifier(replacementView)))
    replacementView.edit?(); replacementView.seek?()
    precondition(edits == [replacement.id] && seeks == [replacement.id])
    let menu = replacementView.regionMenu()
    _ = replacementView.perform(menu.items[0].action!)
    precondition(edits == [replacement.id, replacement.id])

    // A mousedown before the drag threshold reserves the slot outside coverage.
    replacementView.mouseDown(with: event(.leftMouseDown, x: 200))
    project(20000)
    precondition(host.activeForTest[replacement.id] === replacementView && replacementView.hasActiveProjectedGesture)
    replacementView.mouseDragged(with: event(.leftMouseDragged, x: 215))
    replacementView.mouseUp(with: event(.leftMouseUp, x: 218))
    precondition(dragEvents.count == 2 && dragEvents[0].0 == replacement.id && !dragEvents[0].2 &&
        dragEvents[1].0 == replacement.id && dragEvents[1].2 && dragEvents[1].1 == 18)
    precondition(host.activeForTest.isEmpty && host.idleForTest.contains(where: { $0 === replacementView }),
        "release reprojects after the captured gesture is cleared, so an offscreen slot retires immediately")
    assertIdle(host.idleForTest)

    // Structural removal cancels the old captured gesture before slot reuse.
    project()
    let oldView = host.activeForTest[replacement.id]!
    oldView.mouseDown(with: event(.leftMouseDown, x: 200))
    oldView.mouseDragged(with: event(.leftMouseDragged, x: 205))
    let beforeCancellation = dragEvents.count
    let next = target(at: 100, duration: 400)
    host.configure([next]); project()
    let nextView = host.activeForTest[next.id]!
    precondition(nextView === oldView && !nextView.hasActiveProjectedGesture)
    nextView.mouseUp(with: event(.leftMouseUp, x: 220))
    precondition(dragEvents.count == beforeCancellation && seeks.count == 1,
        "the old mouse-up cannot invoke either stale or newly rebound commands")
    nextView.mouseDown(with: event(.leftMouseDown, x: 200))
    nextView.mouseUp(with: event(.leftMouseUp, x: 200))
    precondition(seeks.last == next.id)
    print("REGION_POOL_NEW_IDS_CAPTURED_DRAG_OFFSCREEN_RELEASE_AND_STRUCTURAL_CANCEL_OK")

    // Keep the actual menu reservation/defer, replacing only AppKit's popup
    // function so this test cannot show a menu or take focus from CatLive.
    let afterMenu = target(at: 100, duration: 400)
    let editsBeforeMenu = edits.count
    RegionPoolProbe.menuBody = { view, menu in
        precondition(view === nextView && view.isReservedForProjectionReuse)
        project(20000)
        precondition(host.activeForTest[next.id] === view)
        host.configure([afterMenu]); project()
        precondition(host.activeForTest[afterMenu.id] !== view && host.activeForTest[next.id] === view,
            "an open menu's action target is never reassigned to a different UUID")
        precondition(view.projectedInputBounds.isEmpty)
        _ = view.perform(menu.items[0].action!)
        precondition(edits.count == editsBeforeMenu, "removed UUID menu commands are disabled immediately")
    }
    nextView.rightMouseDown(with: event(.rightMouseDown, x: 200))
    RegionPoolProbe.menuBody = nil
    precondition(!nextView.isReservedForProjectionReuse && host.activeForTest[next.id] == nil)
    precondition(host.idleForTest.contains(where: { $0 === nextView }))
    assertIdle(host.idleForTest)
    print("REGION_POOL_MENU_RESERVATION_DELETION_NO_CALLBACK_REBIND_OK")

    // Bound retained idle views after a dense wide view, while preserving all
    // currently needed regions. Shrinking the pool may remove only the excess.
    let many = (0..<150).map { _ in target(at: 100, duration: 100) }
    host.configure(many); project()
    precondition(host.activeForTest.count == 150)
    project(900000)
    precondition(host.activeForTest.isEmpty && host.idleForTest.count == 64 && host.subviews.count == 64)
    assertIdle(host.idleForTest)
    host.configure([])
    precondition(host.activeForTest.isEmpty && host.idleForTest.count <= 64)

    // Huge logical coordinates remain vectors; only the selected shape layer's
    // bounded tile is drawable, and empty pooled slots have no raster content.
    host.frame.size.width = 100_000_000
    let long = target(at: 0, duration: 90_000_000, selected: true)
    host.configure([long]); project(40_000_000)
    let longView = host.activeForTest[long.id]!, selection = host.selectionForTest[long.id]!
    precondition(longView.frame.width == 100_000_000 && longView.wantsUpdateLayer && longView.layer?.contents == nil)
    precondition(longView.projectedInputBounds.width == viewport.width && selection.frame.width == viewport.width &&
        selection.path != nil && !selection.isHidden && selection.contents == nil)
    host.configure([])
    assertIdle(host.idleForTest)
    precondition(host.idleForTest.count <= 64 && host.subviews.count <= 64)
    precondition(!window.isKeyWindow && !window.isVisible, "fixture never activates or displays a window")
    print("REGION_POOL_BOUND64_LARGE_LOGICAL_BOUNDS_VECTOR_ONLY_AND_EMPTY_PROJECT_OK")
}
MainActor.assumeIsolated { runPoolTests() }
