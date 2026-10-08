// Compiled with the actual retained region container and RegionRightClickView.
@MainActor private func runNativeRegionTests() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 120),
        styleMask: .borderless, backing: .buffered, defer: false)
    let container = NativeTimelineRegionTargetsView(frame: CGRect(x: 0, y: 0, width: 100_000, height: 120))
    window.contentView = container
    // NSWindow sizes its content view to the viewport. An actual timeline mount
    // is instead the fixed document plane, so restore that geometry explicitly.
    container.setFrameSize(CGSize(width: 100_000, height: 120))
    let first = UUID(), special = UUID(), distant = UUID()
    var seeks = 0, edits = 0, deletes = 0, detects = 0, unifies = 0, disunifies = 0
    var originalDrags: [(CGFloat, Bool, Int)] = [], replacementDrags: [(CGFloat, Bool, Int)] = []
    func targets(previewStart: Double = 10, replacement: Bool = false, selected: Bool = true,
                 pinnedDistant: Bool = false) -> [NativeTimelineRegionTarget] {
        let command = RegionRightClick(edit: { edits += 1 }, unify: { unifies += 1 },
            detectBPM: { detects += 1 }, delete: { deletes += 1 }, seek: { seeks += 1 },
            drag: { delta, ended, edge in
                if replacement { replacementDrags.append((delta, ended, edge)) }
                else { originalDrags.append((delta, ended, edge)) }
            })
        return [
            .init(id: first, start: previewStart, end: 30, lane: 0, edgePadding: 10,
                selected: selected, pinned: false, input: command),
            .init(id: special, start: 12, end: 22, lane: 1, edgePadding: 0, selected: false, pinned: false,
                input: RegionRightClick(edit: { edits += 1 }, disunify: { disunifies += 1 },
                    resizable: false, drag: { originalDrags.append(($0, $1, $2)) })),
            .init(id: distant, start: 8_000, end: 8_050, lane: 0, edgePadding: 10,
                selected: false, pinned: pinnedDistant, input: command)
        ]
    }
    let viewport = CGRect(x: 0, y: 0, width: 700, height: 80)
    container.configure(targets())
    container.project(scale: 10, viewport: viewport)
    let firstView = container.viewForTest(first)!
    let specialView = container.viewForTest(special)!
    precondition(firstView.projectedInputBounds == CGRect(x: 90, y: -4, width: 220, height: 24))
    precondition(specialView.projectedInputBounds == CGRect(x: 120, y: 16, width: 100, height: 16))
    precondition(!specialView.resizable && container.viewForTest(distant) == nil,
        "unified regions retain their move-only band; cold offscreen targets are not mounted")
    let selection = container.selectionForTest(first)!
    precondition(!selection.isHidden && selection.lineWidth == 1.5)
    precondition(selection.path!.boundingBox == CGRect(x: 10.75, y: 4.75, width: 198.5, height: 14.5),
        "selection matches the old strokeBorder inside the padded resize hit target")
    func event(_ type: NSEvent.EventType, in view: NSView, x: CGFloat, y: CGFloat = 12,
               flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(NSPoint(x: x + (view as! RegionRightClickView).projectedInputBounds.minX, y: y + (view as! RegionRightClickView).projectedInputBounds.minY), to: nil),
            modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    func windowEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    precondition(container.hitTest(container.convert(NSPoint(x: 200, y: 10), to: container.superview)) === firstView)
    precondition(container.hitTest(container.convert(NSPoint(x: 600, y: 60), to: container.superview)) == nil,
        "empty header space must continue to the other timeline inputs")
    let initialContainerFrame = container.frame, initialContainerBounds = container.bounds
    for index in 0..<120 {
        container.project(scale: 10 + CGFloat(index % 20), viewport: viewport)
        precondition(container.viewForTest(first) === firstView && container.viewForTest(special) === specialView,
            "zoom must retain AppKit input identity, including its in-flight gesture")
        precondition(container.frame == initialContainerFrame && container.bounds == initialContainerBounds,
            "region projection cannot resize its hosting boundary")
        precondition(firstView.frame == container.bounds && specialView.frame == container.bounds,
            "native input frames remain fixed instead of moving each view on zoom")
    }
    container.project(scale: 10, viewport: viewport)
    firstView.mouseDown(with: event(.leftMouseDown, in: firstView, x: 100))
    precondition(seeks == 0)
    firstView.mouseUp(with: event(.leftMouseUp, in: firstView, x: 100))
    precondition(seeks == 1)
    firstView.mouseDown(with: event(.leftMouseDown, in: firstView, x: 100, flags: .option))
    firstView.mouseUp(with: event(.leftMouseUp, in: firstView, x: 100, flags: .option))
    precondition(deletes == 1 && seeks == 1)
    let menu = firstView.regionMenu()
    precondition(menu.items.count == 4)
    for item in menu.items { NSApp.sendAction(item.action!, to: item.target, from: item) }
    precondition(edits == 1 && detects == 1 && unifies == 1 && deletes == 2,
        "the existing menu must retain all region actions")
    let specialMenu = specialView.regionMenu()
    precondition(specialMenu.items.count == 2)
    NSApp.sendAction(specialMenu.items[1].action!, to: specialMenu.items[1].target, from: specialMenu.items[1])
    precondition(disunifies == 1)

    let down = firstView.convert(NSPoint(x: firstView.projectedInputBounds.minX + 12, y: firstView.projectedInputBounds.minY + 12), to: nil)
    firstView.mouseDown(with: windowEvent(.leftMouseDown, at: down))
    firstView.mouseDragged(with: windowEvent(.leftMouseDragged, at: NSPoint(x: down.x + 9, y: down.y)))
    precondition(container.activeDragsForTest == [first])
    container.configure(targets(previewStart: 11, replacement: true, selected: false))
    container.project(scale: 20, viewport: CGRect(x: 70_000, y: 0, width: 700, height: 80))
    precondition(container.viewForTest(first) === firstView,
        "an active drag survives preview reconfiguration and offscreen projection")
    precondition(container.selectionForTest(first)!.isHidden)
    firstView.mouseDragged(with: windowEvent(.leftMouseDragged, at: NSPoint(x: down.x + 15, y: down.y)))
    firstView.mouseUp(with: windowEvent(.leftMouseUp, at: NSPoint(x: down.x + 17, y: down.y)))
    precondition(originalDrags.map { $0.0 } == [9, 15, 17] && originalDrags.map { $0.1 } == [false, false, true])
    precondition(originalDrags.allSatisfy { $0.2 == -1 } && replacementDrags.isEmpty,
        "reprojection must not change captured edge, window displacement or command")
    precondition(container.activeDragsForTest.isEmpty && container.viewForTest(first) == nil,
        "released offscreen inputs must leave the native hierarchy")

    container.configure(targets(replacement: true, pinnedDistant: true))
    container.project(scale: 10, viewport: viewport)
    precondition(container.viewForTest(distant) != nil, "an open editor's region stays mounted outside the viewport")
    let nextView = container.viewForTest(first)!
    nextView.mouseDown(with: event(.leftMouseDown, in: nextView, x: 100))
    NativeTimelineInputGate.shared.cancelPendingClicks(for: window)
    nextView.mouseUp(with: event(.leftMouseUp, in: nextView, x: 100))
    precondition(seeks == 1, "wheel cancellation cannot leave a latent region seek")
    nextView.mouseDown(with: event(.leftMouseDown, in: nextView, x: 100))
    nextView.mouseDragged(with: event(.leftMouseDragged, in: nextView, x: 120))
    precondition(container.activeDragsForTest == [first])
    let beforeBlocking = replacementDrags.count
    NativeTimelineInputGate.shared.setBlocked(true, for: window)
    NativeTimelineInputGate.shared.setBlocked(false, for: window)
    nextView.mouseUp(with: event(.leftMouseUp, in: nextView, x: 140))
    precondition(container.activeDragsForTest.isEmpty && replacementDrags.count == beforeBlocking,
        "modal cancellation clears both retained membership and the original gesture")
    container.configure(Array(targets().reversed()))
    container.project(scale: 10, viewport: viewport)
    precondition(container.orderForTest == [special, first])
    precondition(container.subviews.last === container.viewForTest(first),
        "structural order changes must preserve the old ForEach overlap precedence")
    container.configure([])
    precondition(container.viewForTest(first) == nil && container.viewForTest(special) == nil &&
        container.orderForTest.isEmpty && container.activeDragsForTest.isEmpty && container.subviews.count <= 64,
        "song removal releases all active regions while retaining only the bounded inactive pool")
    for case let input as RegionRightClickView in container.subviews {
        precondition(input.projectedInputBounds.isEmpty && !input.isReservedForProjectionReuse &&
            input.edit == nil && input.detectBPM == nil && input.unify == nil && input.disunify == nil &&
            input.delete == nil && input.drag == nil && input.seek == nil && input.projectedInteractionEnded == nil,
            "a pooled region must retain neither an input target nor a command from the removed song")
    }
    print("NATIVE_REGIONS_OK: retained zoom geometry/selection, culling, active drag, resize, menus, cancellation and cleanup")
}
MainActor.assumeIsolated { runNativeRegionTests() }
