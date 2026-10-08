@MainActor private func runClippedRegionTests() {
    let window = NSWindow(contentRect: CGRect(x: -10000, y: 0, width: 700, height: 120),
        styleMask: .borderless, backing: .buffered, defer: false)
    let clip = NSClipView(frame: CGRect(x: 0, y: 0, width: 700, height: 120))
    window.contentView = clip
    let container = NativeTimelineRegionTargetsView(frame: CGRect(x: 0, y: 0, width: 1_000_000, height: 120))
    clip.documentView = container
    clip.scroll(to: CGPoint(x: 512, y: 0))
    let viewport = CGRect(x: 512, y: 0, width: 700, height: 120)
    let wide = UUID()
    var drags: [(CGFloat, Bool, Int)] = [], deletes = 0, seeks = 0
    let command = RegionRightClick(edit: {}, delete: { deletes += 1 }, seek: { seeks += 1 },
        drag: { drags.append(($0, $1, $2)) })
    func target(_ start: Double, _ end: Double, padding: CGFloat = 10, pinned: Bool = false) -> NativeTimelineRegionTarget {
        .init(id: wide, start: start, end: end, lane: 0, edgePadding: padding,
            selected: true, pinned: pinned, input: command)
    }
    container.configure([target(0, 100_000)])
    container.project(scale: 1, viewport: viewport)
    let view = container.viewForTest(wide)!
    precondition(view.projectedInputBounds == CGRect(x: viewport.minX, y: -4, width: viewport.width, height: 24))
    precondition(view.layer!.masksToBounds, "a partial selection outline clips to the bounded native surface")
    let initial = view.frame
    let invalidations = view.projectionInvalidationsForTest
    for step in 1...400 {
        container.project(scale: 1 + Double(step) / 7, viewport: viewport)
        precondition(view.frame == initial && container.viewForTest(wide) === view,
            "a region spanning the tile must retain native frame and input identity throughout zoom")
        precondition(view.edgeForTest(at: 0) == 0 && view.edgeForTest(at: 699.999) == 0,
            "clipped tile edges are never region resize handles")
        precondition(view.cursorRectsForTest.isEmpty,
            "a region continuing beyond both tile edges has no visible resize cursor rectangles")
    }
    precondition(view.projectionInvalidationsForTest == invalidations,
        "offscreen logical edges must not invalidate the window cursor hierarchy during zoom")
    func event(_ type: NSEvent.EventType, local: CGPoint, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(CGPoint(x: local.x + view.projectedInputBounds.minX, y: local.y + view.projectedInputBounds.minY), to: nil), modifierFlags: flags,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    view.mouseMoved(with: event(.mouseMoved, local: CGPoint(x: 1, y: 12)))
    precondition(NSCursor.current == .arrow && view.hoverGripForTest == nil)
    view.mouseDown(with: event(.leftMouseDown, local: CGPoint(x: 1, y: 12)))
    view.mouseDragged(with: event(.leftMouseDragged, local: CGPoint(x: 10.25, y: 12)))
    view.mouseUp(with: event(.leftMouseUp, local: CGPoint(x: 14.5, y: 12)))
    precondition(drags.map { $0.0 } == [9.25, 13.5] && drags.allSatisfy { $0.2 == 0 },
        "dragging beside a clipped edge moves the region using exact window displacement")

    var geometricCases = 0, pixelCases = 0
    let spans: [(Double, Double)] = [(0, 100_000), (0, 570), (490, 530), (500, 515),
        (510, 510.1), (515, 518), (520, 900), (1180, 1220), (1205, 8000)]
    for padding: CGFloat in [0, 10] {
        for scale in [0.125, 1.0, 10.23, 1280.0] {
            for (start, end) in spans {
                let value = target(start / scale, end / scale, padding: padding)
                container.configure([value]); container.project(scale: scale, viewport: viewport)
                guard let projected = container.viewForTest(wide) else { continue }
                let original = value.frame(scale: scale)
                let left = min(viewport.maxX, max(viewport.minX, original.minX))
                let right = min(viewport.maxX, max(viewport.minX, original.maxX))
                precondition(projected.projectedInputBounds == CGRect(x: left, y: original.minY, width: max(0, right - left), height: original.height))
                precondition(projected.logicalRectForTest == original.offsetBy(dx: -left, dy: -original.minY))
                let originalEdge = min(34, max(0, (original.width - 8) / 2))
                for step in 0...100 where projected.inputLocalBoundsForTest.width > 0 {
                    let x = projected.inputLocalBoundsForTest.width * CGFloat(step) / 100
                    let originalX = x + projected.projectedInputBounds.minX - original.minX
                    let expected = originalX <= originalEdge ? -1 : originalX >= original.width - originalEdge ? 1 : 0
                    // A world-coordinate NSView adds the large input origin
                    // before conversion; comparisons exactly on a boundary can
                    // differ by one Double ULP after that addition/subtraction.
                    let onBoundary = min(abs(originalX - originalEdge),
                        abs(originalX - (original.width - originalEdge))) < 0.0000001
                    precondition(projected.edgeForTest(at: x) == expected || onBoundary,
                        "clipping preserves edge geometry beyond subpixel arithmetic boundaries")
                    geometricCases += 1
                }
                guard projected.inputLocalBoundsForTest.width > 0 else { continue }
                let selection = container.selectionForTest(wide)!
                let reference = CGRect(x: original.minX - projected.projectedInputBounds.minX + padding,
                    y: padding > 0 ? 4 : 0, width: max(1, original.width - padding * 2), height: 16)
                    .insetBy(dx: 0.75, dy: 0.75)
                for density: CGFloat in [1, 2] {
                    let pixelWidth = Int(ceil(projected.inputLocalBoundsForTest.width * density))
                    let pixelHeight = Int(ceil(projected.inputLocalBoundsForTest.height * density))
                    func context() -> CGContext {
                        let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                            bytesPerRow: pixelWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                        context.scaleBy(x: density, y: density)
                        context.clip(to: projected.inputLocalBoundsForTest)
                        return context
                    }
                    let expected = context(), actual = context()
                    expected.setStrokeColor(NSColor.white.cgColor); expected.setLineWidth(1.5)
                    expected.stroke(reference)
                    selection.render(in: actual)
                    let expectedBytes = expected.makeImage()!.dataProvider!.data! as Data
                    let actualBytes = actual.makeImage()!.dataProvider!.data! as Data
                    precondition(expectedBytes == actualBytes,
                        "bounded selection must match the full original outline clipped to its viewport at 1x/2x")
                    pixelCases += 1
                }
            }
        }
    }
    // Offscreen mounted views must continue receiving their captured gesture;
    // a zero-width native frame must not make their logical body disappear.
    container.configure([target(50, 75, pinned: true)])
    container.project(scale: 10, viewport: viewport)
    let pinned = container.viewForTest(wide)!
    let down = pinned.convert(CGPoint(x: pinned.projectedInputBounds.minX + 80, y: pinned.projectedInputBounds.minY + 12), to: nil)
    func windowEvent(_ type: NSEvent.EventType, point: CGPoint, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    pinned.mouseDown(with: windowEvent(.leftMouseDown, point: down, flags: .option))
    container.project(scale: 10, viewport: CGRect(x: 70_000, y: 0, width: 700, height: 120))
    precondition(container.viewForTest(wide) === pinned && pinned.inputLocalBoundsForTest.width == 0 && !pinned.isHidden)
    pinned.mouseUp(with: windowEvent(.leftMouseUp, point: down, flags: .option))
    precondition(deletes == 1, "Option release containment retains the original logical region after clipping")
    container.project(scale: 10, viewport: viewport)
    pinned.mouseDown(with: windowEvent(.leftMouseDown, point: down))
    pinned.mouseUp(with: windowEvent(.leftMouseUp, point: down))
    precondition(seeks == 1)
    print("CLIPPED_REGION_OK stableFrames=400 exactEdges=\(geometricCases) exactOutlinePixels=\(pixelCases) capturedInput=true")
}
MainActor.assumeIsolated { runClippedRegionTests() }

// Exercise the stable parent target, cursor transitions and full hit-test tree
// without activating a real application window during the standalone fixture.
@MainActor private final class NativeRegionCursorWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}
@MainActor private func runStableRegionPointerTests() {
    let window = NativeRegionCursorWindow(contentRect: CGRect(x: -10000, y: -10000, width: 700, height: 120),
        styleMask: .borderless, backing: .buffered, defer: false)
    let clip = NSClipView(frame: CGRect(x: 0, y: 0, width: 700, height: 120))
    window.contentView = clip
    let container = NativeTimelineRegionTargetsView(frame: CGRect(x: 0, y: 0, width: 2_000_000_000, height: 120))
    clip.documentView = container
    let id = UUID(), secondID = UUID()
    for origin: CGFloat in [0, 430_000, 1_770_000_000] {
        clip.scroll(to: CGPoint(x: origin, y: 0))
        let input = RegionRightClick(edit: {})
        let targets: [NativeTimelineRegionTarget] = [
            .init(id: id, start: Double(origin + 100), end: Double(origin + 300), lane: 0,
                edgePadding: 10, selected: true, pinned: false, input: input),
            .init(id: secondID, start: Double(origin + 150), end: Double(origin + 250), lane: 0,
                edgePadding: 10, selected: false, pinned: false, input: input)
        ]
        container.configure(targets)
        container.project(scale: 1, viewport: CGRect(x: origin, y: 0, width: 700, height: 120))
        container.updateTrackingAreas()
        let first = container.viewForTest(id)!, second = container.viewForTest(secondID)!
        first.updateTrackingAreas(); second.updateTrackingAreas()
        precondition(first.trackingAreas.isEmpty && second.trackingAreas.isEmpty,
            "only the region parent may own tracking; per-target areas must be absent")
        precondition(container.trackingAreas.count == 1 && container.trackingAreas[0].rect.maxY == 20,
            "region tracking must stop at the band and never cover marker/grid lanes")
        precondition(!container.trackingAreas[0].options.contains(.inVisibleRect),
            "inVisibleRect would silently expand tracking across the entire timeline")
        func move(_ x: CGFloat, y: CGFloat = 8) {
            let point = container.convert(CGPoint(x: origin + x, y: y), to: nil)
            let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
            container.mouseMoved(with: event)
        }
        precondition(container.hitTest(CGPoint(x: origin + 200, y: 8)) === second,
            "equal-frame target subviews preserve the last-region overlap precedence")
        precondition(container.hitTest(CGPoint(x: origin + 600, y: 8)) == nil)
        precondition(container.hitTest(CGPoint(x: origin + 200, y: 50)) == nil)
        move(105); precondition(NSCursor.current == .resizeLeftRight && first.hoverGripForTest != nil)
        move(200); precondition(NSCursor.current == .arrow && first.hoverGripForTest == nil)
        move(255); precondition(NSCursor.current == .resizeLeftRight && second.hoverGripForTest != nil)
        move(600); precondition(NSCursor.current == .arrow && second.hoverGripForTest == nil)
        move(105); precondition(NSCursor.current == .resizeLeftRight)
        move(105, y: 60); precondition(NSCursor.current == .arrow && first.hoverGripForTest == nil)
        NativeTimelineInputGate.shared.setBlocked(true, for: window)
        precondition(container.hitTest(CGPoint(x: origin + 105, y: 8)) == nil)
        NativeTimelineInputGate.shared.setBlocked(false, for: window)
        precondition(first.layer?.contents == nil && second.layer?.contents == nil,
            "stable document-sized input hosts must not carry raster contents")
        move(105); precondition(NSCursor.current == .resizeLeftRight)
        container.configure(Array(targets.dropFirst()))
        container.project(scale: 1, viewport: CGRect(x: origin, y: 0, width: 700, height: 120))
        precondition(container.viewForTest(id) == nil && NSCursor.current == .arrow,
            "removing the hovered target must release its cursor before dropping the view")
        container.configure(targets)
        container.project(scale: 1, viewport: CGRect(x: origin, y: 0, width: 700, height: 120))
        move(105); precondition(NSCursor.current == .resizeLeftRight)
        container.project(scale: 100, viewport: CGRect(x: origin, y: 0, width: 700, height: 120))
        precondition(container.viewForTest(id) == nil && NSCursor.current == .arrow,
            "zoom culling must not leave a stationary pointer stuck in the resize cursor")
    }
    print("NATIVE_REGION_STABLE_POINTER_OK origin/6h/maxzoom overlap/edges/exit/gate/no-body-tracking")
}
MainActor.assumeIsolated { runStableRegionPointerTests() }
