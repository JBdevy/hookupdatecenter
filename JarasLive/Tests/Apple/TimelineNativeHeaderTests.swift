setbuf(stdout,nil)
// Frozen immediate renderer from before the retained-layer migration.
// This independent reference verifies palette, geometry and text composition.
extension NativeTimelineHeaderView {
    func drawOriginalForTest(in context: CGContext) {
        guard configuration != nil else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.translateBy(x: -tile.minX, y: 0)
        for region in regions {
            let part = region.part
            let rect = CGRect(x: part.startTime * scale, y: CGFloat(region.lane) * 16,
                width: max(1, (part.endTime - part.startTime) * scale), height: 16)
            guard rect.intersects(tile) else { continue }
            context.setFillColor(region.fill); context.fill(rect)
            if let identifier = TimelineStaticText.label(region.identifier, style: .regionIdentifier, displayScale: displayScale), rect.width >= identifier.width + 8 {
                context.saveGState(); context.clip(to: rect)
                NativeTimelineHeaderText.draw(identifier.image, size: identifier.size,
                    at: CGPoint(x: rect.maxX - 4 - identifier.width - 1, y: rect.minY + 2), in: context)
                drawName(region.name, rect: CGRect(x: rect.minX, y: rect.minY,
                    width: max(0, rect.width - identifier.width - 8), height: rect.height), color: 0xffffff, centered: false, context: context)
                context.restoreGState()
            }
        }
        for item in projectedMarkers {
            let x = item.marker.position * scale
            if x >= tile.minX - 1, x <= tile.maxX + 1 {
                context.saveGState()
                context.setStrokeColor(item.colors.stem)
                context.setLineWidth(1); context.setLineDash(phase: 0, lengths: item.tempo ? [2, 3] : [])
                context.move(to: CGPoint(x: x, y: item.top + markerLaneHeight)); context.addLine(to: CGPoint(x: x, y: tile.height)); context.strokePath()
                context.restoreGState()
            }
            guard item.rect.intersects(tile) else { continue }
            let rect = item.rect
            if item.tempo {
                let path = CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 4, cornerHeight: 4, transform: nil)
                context.addPath(path); context.setFillColor(displayColor); context.fillPath()
                context.addPath(path); context.setStrokeColor(lineColor); context.setLineWidth(1); context.strokePath()
            } else {
                context.setFillColor(item.colors.fill)
                if item.marker.isSection {
                    let path = CGMutablePath()
                    path.move(to: CGPoint(x: rect.minX, y: rect.midY)); path.addLine(to: CGPoint(x: rect.minX + min(7, rect.width / 2), y: rect.minY))
                    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                    path.addLine(to: CGPoint(x: rect.minX + min(7, rect.width / 2), y: rect.maxY)); path.closeSubpath()
                    context.addPath(path); context.fillPath()
                } else if item.marker.sourceRegionID != nil || item.marker.unifiedRegionID != nil {
                    let path = CGPath(roundedRect: rect.insetBy(dx: 0.6, dy: 0.6), cornerWidth: 3, cornerHeight: 3, transform: nil)
                    context.addPath(path); context.fillPath()
                    context.addPath(path); context.setStrokeColor(linkedOutlineColor); context.setLineWidth(1.2); context.strokePath()
                } else { context.fill(rect) }
            }
            drawName(item.label, rect: rect, color: item.tempo ? 0xffffff : 0, centered: item.tempo, context: context)
        }
        // These boundaries previously overlaid the entire pinned header/body.
        for region in regions {
            let left = region.part.startTime * scale, right = region.part.endTime * scale
            guard right >= tile.minX - 6, left <= tile.maxX + 6 else { continue }
            let top = CGFloat(region.lane + 1) * 16
            context.saveGState()
            context.clip(to: CGRect(x: left, y: top, width: max(0, right - left), height: max(0, tile.height - top)))
            let path = CGMutablePath()
            for x in [left, right] where x >= tile.minX - 6 && x <= tile.maxX + 6 {
                path.move(to: CGPoint(x: x, y: top)); path.addLine(to: CGPoint(x: x, y: tile.height))
            }
            for boundary in region.boundaries {
                context.addPath(path); context.setLineWidth(boundary.width)
                context.setStrokeColor(boundary.color); context.strokePath()
            }
            context.restoreGState()
        }
    }
    private func drawName(_ name: String, rect: CGRect, color: UInt32, centered: Bool, context: CGContext) {
        let available = rect.width - 8
        guard available >= 10, rect.intersects(tile) else { return }
        let measure: (String) -> CGFloat = { NativeTimelineHeaderText.label($0, color: color, scale: self.displayScale)?.width ?? 0 }
        let metrics = TimelineNameMetrics.metrics(name, measure: measure)
        guard centered || rect.minX + 4 + min(available, metrics.fullWidth) >= tile.minX,
              let displayed = metrics.fitting(name, width: available, measure: measure),
              let label = NativeTimelineHeaderText.label(displayed, color: color, scale: displayScale) else { return }
        context.saveGState()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)); context.clip()
        let point = centered ? CGPoint(x: rect.midX - label.width / 2 - 1, y: rect.midY - label.size.height / 2)
            : CGPoint(x: rect.minX + 3, y: rect.minY + 2)
        NativeTimelineHeaderText.draw(label.image, size: label.size, at: point, in: context)
        context.restoreGState()
    }
}

@MainActor private func runNativeHeaderTests() {
    // Each cached entry uses exactly the previous conversion/color space,
    // including the distinct opaque-fill and withAlphaComponent(1) paths.
    let colorAlphas: [CGFloat?] = [nil, 0.14, 0.30, 0.45, 1]
    for hex in [UInt32(0), 0xffffff, 0x705264, 0x885965, 0x40a050, 0x999999] {
        for alpha in colorAlphas {
            let base = NSColor(Color(hex: hex))
            let original = (alpha.map { base.withAlphaComponent($0) } ?? base).cgColor
            let cached = NativeTimelineHeaderColors.color(hex, alpha: alpha)
            precondition(cached == original && cached.colorSpace == original.colorSpace && cached.components == original.components,
                "cached header colors must preserve the exact original components and color space")
            precondition(cached === NativeTimelineHeaderColors.color(hex, alpha: alpha),
                "repeated drawing colors retain the same CGColor object")
        }
    }
    let region = Part(id: UUID(), name: "Verso áÉção", startTime: 10, endTime: 30, color: 0x705264)
    let parent = Part(id: UUID(), name: "Special", startTime: 40, endTime: 55, color: 0x885965)
    let child = Part(id: UUID(), name: "Child", startTime: 40, endTime: 48, parentRegionID: parent.id)
    let ordinary = TimelineMarker(id: UUID(), name: "Bridge", position: 6, color: 0x40a050)
    let tied = TimelineMarker(id: UUID(), name: "Tied", position: 6, color: 0x4080c0)
    let section = TimelineMarker(id: UUID(), name: "Chorus", position: 14, color: 0xff9030, section: true)
    let linked = TimelineMarker(id: UUID(), name: "Source", position: 23, color: 0xb080e0, sourceRegionID: region.id)
    let tempo = TimelineMarker(id: UUID(), name: "TEMPO", position: 34, color: 0x999999, tempoBPM: 128, tempoBeats: 3, tempoUnit: 4)
    var song = Song(id: UUID(), name: "Header", duration: 100, bpm: 120, tracks: [],
        parts: [region, parent, child], markers: [ordinary, tied, section, linked, tempo])
    let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 700, height: 240),
        styleMask: .borderless, backing: .buffered, defer: false)
    let host = NSView(frame: CGRect(x: 0, y: 0, width: 100_000, height: 240))
    window.contentView = host
    let header = NativeTimelineHeaderView(); host.addSubview(header)
    var edits: [UUID] = [], deletes: [UUID] = [], seeks: [UUID] = [], moved: [TimelineMarker] = []
    func configuration() -> NativeTimelineHeaderConfiguration {
        let lanes = RegionLanes(parts: song.parts)
        let targets = song.parts.filter { $0.parentRegionID == nil }.map {
            NativeTimelineRegionTarget(id: $0.id, start: $0.startTime, end: $0.endTime,
                lane: lanes.lanes[$0.id] ?? 0, edgePadding: $0.id == parent.id ? 0 : 10,
                selected: $0.id == region.id, pinned: false, input: RegionRightClick(edit: {}))
        }
        return .init(song: song, lanes: lanes, parentIDs: [parent.id], regionTargets: targets,
            edit: { edits.append($0.id) }, delete: { deletes.append($0) },
            seek: { seeks.append($0.id) }, move: { moved.append($0) })
    }
    header.configure(configuration())
    let viewport = CGRect(x: 0, y: 0, width: 700, height: 240)
    header.project(scale: 10, viewport: viewport, layoutWidth: 100_000, displayScale: 2)
    precondition(header.identifiersForTest == ["0st  01", JarasLocalization.string("Special")])
    precondition(header.colorsForTest == [0x705264, 0x885965])
    let labels = Dictionary(uniqueKeysWithValues: header.markersForTest.map { ($0.0, $0.2) })
    precondition(labels[section.id] == "CHORUS" && labels[linked.id] == "0st  Source" && labels[tempo.id] == "128  3/4",
        "section casing, source pitch and tempo formatting remain model-defined")
    // Draw the real native implementation into a bitmap, including every flag
    // shape and label path. Sample interiors independently of antialiasing.
    let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(header.drawingForTest.bounds.width), pixelsHigh: 240,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: pixels)
    let cg = NSGraphicsContext.current!.cgContext
    cg.translateBy(x: 0, y: 240); cg.scaleBy(x: 1, y: -1)
    header.drawOriginalForTest(in: cg)
    NSGraphicsContext.restoreGraphicsState()
    func pixel(_ x: Int, _ y: Int) -> UInt32 {
        let color = pixels.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
        return UInt32((color.redComponent * 255).rounded()) << 16
            | UInt32((color.greenComponent * 255).rounded()) << 8 | UInt32((color.blueComponent * 255).rounded())
    }
    precondition(pixel(200, 8) == 0x705264 && pixel(470, 8) == 0x885965,
        "region fills retain their exact chosen colors")
    precondition(pixel(62, 28) == 0x4080c0 && pixel(343, 40) == 0x141414,
        "normal flags and BPM display retain their original fills and lane positions")
    try! pixels.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/catlive-native-header-fixture.png"))
    func compareRetainedPixels(scale: CGFloat, offset: CGFloat, backing: CGFloat, name: String) {
        header.project(scale: scale, viewport: CGRect(x: offset, y: 0, width: 700, height: 240),
            layoutWidth: 200_000_000, displayScale: backing)
        let width = Int(header.drawingForTest.bounds.width * backing), height = Int(header.drawingForTest.bounds.height * backing)
        func context() -> CGContext {
            let value = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            value.translateBy(x: 0, y: CGFloat(height)); value.scaleBy(x: backing, y: -backing)
            return value
        }
        let reference = context(); header.drawOriginalForTest(in: reference)
        let retained = context(); header.drawingForTest.render(in: retained)
        let image = retained.makeImage()!, expected = reference.makeImage()!
        let bytes = image.dataProvider!.data! as Data, original = expected.dataProvider!.data! as Data
        var changed = 0, active = 0, maxDifference = 0, differenceTotal = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            if bytes[index + 3] != 0 || original[index + 3] != 0 { active += 1 }
            if (0..<4).contains(where: { bytes[index + $0] != original[index + $0] }) {
                changed += 1
            }
            for channel in 0..<4 {
                let difference = abs(Int(bytes[index + channel]) - Int(original[index + channel]))
                maxDifference = max(maxDifference, difference); differenceTotal += difference
            }
        }
        print("RETAINED_HEADER_PIXELS \(name) \(backing)x: \(changed)/\(active) changed, max=\(maxDifference), total=\(differenceTotal)")
        // Integer retina projections match exactly. Fractional coverage may
        // round by one component; at1x three edge pixels of the half-point BPM
        // text image use a slightly different Core Animation interpolation.
        if backing == 2 {
            precondition(maxDifference <= 1 && differenceTotal <= active / 100,
                "retained retina geometry/text must match the original within one antialias component")
            if name != "fractional" { precondition(changed == 0) }
        } else {
            precondition(maxDifference <= 16 && differenceTotal <= active / 40 + 1,
                "1x differences must stay confined to antialias rounding of the original edges")
        }
        let rep = NSBitmapImageRep(cgImage: image)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/catlive-native-header-retained-\(name)-\(Int(backing))x.png"))
        if name == "base" {
            for point in [CGPoint(x: 200, y: 8), CGPoint(x: 470, y: 8), CGPoint(x: 62, y: 28), CGPoint(x: 343, y: 40)] {
                let index = Int(point.y * backing) * image.bytesPerRow + Int(point.x * backing) * 4
                precondition(bytes[index..<(index + 4)] == original[index..<(index + 4)],
                    "retained region/flag/BPM fills keep exact RGBA values at the original positions")
            }
            // Render through the real backing root as well, with native input
            // sublayers above it. The retained drawing must stay at visual top.
            let root = context(); header.layer!.render(in: root)
            let rootImage = root.makeImage()!, rootBytes = rootImage.dataProvider!.data! as Data
            let index = Int(8 * backing) * rootImage.bytesPerRow + Int(200 * backing) * 4
            precondition(rootBytes[index..<(index + 4)] == original[index..<(index + 4)])
        }
    }
    for backing: CGFloat in [1, 2] {
        compareRetainedPixels(scale: 10, offset: 0, backing: backing, name: "base")
        compareRetainedPixels(scale: 0.5, offset: 0, backing: backing, name: "narrow")
        compareRetainedPixels(scale: 10.23, offset: 0, backing: backing, name: "fractional")
        compareRetainedPixels(scale: 25.3, offset: 1024, backing: backing, name: "clipped")
    }
    header.project(scale: 10, viewport: viewport, layoutWidth: 100_000, displayScale: 2)
    let markerLane = (song.markers ?? []).filter { !$0.isTempo }
    let targets = MarkerTargetGeometry.visible(markerLane, scale: 10, viewport: header.frame,
        facesLeft: false, regionEnds: song.markerRegionEnds, draggingID: nil, label: song.markerLabel)
    for target in targets {
        let actual = header.markerForTest(target.id)!
        precondition(actual.clickBounds.origin.x == target.left && actual.clickBounds.width == target.width,
            "native hit targets preserve the existing collision/8-point-minimum geometry")
    }
    precondition(header.markerForTest(linked.id)?.drag == nil && header.markerForTest(tempo.id)?.drag != nil)
    let originalIDs = Dictionary(uniqueKeysWithValues: (song.markers ?? []).compactMap { marker in
        header.markerForTest(marker.id).map { (marker.id, ObjectIdentifier($0)) }
    })
    // Following playback changes the real scroll origin on every tick. A
    // prepared header bucket must reuse both pixels and native input commands.
    let initialRedrawRequests = header.redrawRequestsForTest
    let initialMarkerConfigurations = header.markerConfigurationsForTest
    let initialRegionProjections = header.regionProjectionsForTest
    for index in 0..<160 {
        let offset = CGFloat(index) * 3.2
        header.needsDisplay = false
        header.project(scale: 10, viewport: CGRect(x: offset, y: 0, width: 700, height: 240),
            layoutWidth: 100_000, displayScale: 2)
        precondition(header.redrawRequestsForTest == initialRedrawRequests && header.markerConfigurationsForTest == initialMarkerConfigurations &&
            header.regionProjectionsForTest == initialRegionProjections,
            "continuous scroll inside prepared coverage must not redraw or rebuild targets")
        precondition(header.viewportForTest.minX == offset,
            "even a no-op projection keeps the live viewport for preview/cancel rerenders")
    }
    header.project(scale: 10, viewport: CGRect(x: 512, y: 0, width: 700, height: 240),
        layoutWidth: 100_000, displayScale: 2)
    precondition(header.redrawRequestsForTest == initialRedrawRequests + 1 && header.regionProjectionsForTest == initialRegionProjections + 1,
        "crossing a prepared bucket rebuilds the new coverage exactly once")
    header.needsDisplay = false
    header.configure(configuration())
    header.project(scale: 10, viewport: CGRect(x: 512, y: 0, width: 700, height: 240),
        layoutWidth: 100_000, displayScale: 2)
    precondition(header.redrawRequestsForTest == initialRedrawRequests + 2 && header.regionProjectionsForTest == initialRegionProjections + 2,
        "structural edits invalidate unchanged viewport geometry")
    header.project(scale: 10, viewport: viewport, layoutWidth: 100_000, displayScale: 2)
    let initialFrame = header.frame, initialBounds = header.bounds
    let retainedRegions = header.retainedRegionsForTest, retainedMarkers = header.retainedMarkersForTest
    let retainedBoundaries = header.retainedBoundariesForTest, initialTextAssignments = header.textAssignmentsForTest
    for index in 0..<80 {
        header.project(scale: 9 + CGFloat(index % 4), viewport: CGRect(x: CGFloat(index) * 6.4, y: 0, width: 700, height: 240),
            layoutWidth: 100_000, displayScale: 2)
        precondition(header.frame == initialFrame && header.bounds == initialBounds,
            "header backing geometry stays fixed within the horizontal bucket")
        for marker in song.markers ?? [] {
            if let view = header.markerForTest(marker.id), let identity = originalIDs[marker.id] {
                precondition(ObjectIdentifier(view) == identity)
            }
        }
        precondition(retainedRegions.allSatisfy { header.retainedRegionsForTest[$0.key] === $0.value } &&
            retainedMarkers.allSatisfy { header.retainedMarkersForTest[$0.key] === $0.value } &&
            retainedBoundaries.allSatisfy { header.retainedBoundariesForTest[$0.key] === $0.value },
            "zoom retains the same region, flag and boundary layers by UUID")
        precondition(header.textAssignmentsForTest == initialTextAssignments,
            "zoom that keeps the displayed strings must not upload label images again")
        precondition(header.drawingForTest.superlayer === header.layer && header.drawingForTest.frame == header.tileForTest,
            "AppKit input reordering preserves the retained drawing below the native controls")
    }
    header.project(scale: 10, viewport: viewport, layoutWidth: 100_000, displayScale: 2)
    func event(_ type: NSEvent.EventType, view: NSView, x: CGFloat = 5, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(CGPoint(x: (view as? MarkerEditClickView)?.clickBounds.minX ?? 0, y: (view as? MarkerEditClickView)?.clickBounds.minY ?? 0).applying(CGAffineTransform(translationX: x,y:5)), to: nil), modifierFlags: flags,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    let ordinaryView = header.markerForTest(ordinary.id)!
    ordinaryView.mouseDown(with: event(.leftMouseDown, view: ordinaryView))
    ordinaryView.mouseUp(with: event(.leftMouseUp, view: ordinaryView))
    precondition(seeks == [ordinary.id])
    ordinaryView.action?(); ordinaryView.optionClick?()
    header.markerForTest(linked.id)?.optionClick?()
    precondition(edits == [ordinary.id] && deletes == [ordinary.id], "linked flags retain edit but cannot be deleted")
    let tempoView = header.markerForTest(tempo.id)!
    let point = tempoView.convert(CGPoint(x: tempoView.clickBounds.minX + 5, y: tempoView.clickBounds.minY + 5), to: nil)
    func dragEvent(_ type: NSEvent.EventType, delta: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: point.x + delta, y: point.y), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    tempoView.mouseDown(with: dragEvent(.leftMouseDown, delta: 0))
    header.needsDisplay = false
    let beforePreview = header.regionProjectionsForTest
    let redrawsBeforePreview = header.redrawRequestsForTest
    tempoView.mouseDragged(with: dragEvent(.leftMouseDragged, delta: 15.25))
    precondition(header.redrawRequestsForTest == redrawsBeforePreview + 1 && header.regionProjectionsForTest == beforePreview + 1,
        "a local preview invalidates a geometrically unchanged projection")
    precondition(header.previewForTest?.position == 35.525 && moved.isEmpty,
        "native marker drag changes only local preview before release")
    header.configure(configuration())
    header.project(scale: 11, viewport: CGRect(x: 10_000, y: 0, width: 700, height: 240), layoutWidth: 100_000, displayScale: 2)
    precondition(header.markerForTest(tempo.id) === tempoView, "active drag stays mounted across zoom, structural refresh and offscreen pan")
    tempoView.mouseDragged(with: dragEvent(.leftMouseDragged, delta: 18.75))
    tempoView.mouseUp(with: dragEvent(.leftMouseUp, delta: 20.25))
    precondition(moved.count == 1 && moved[0].position == 36.025 && header.previewForTest == nil,
        "captured marker and scale preserve original drag semantics, with one commit on release")
    header.project(scale: 10, viewport: viewport, layoutWidth: 100_000, displayScale: 2)
    let nextTempo = header.markerForTest(tempo.id)!
    nextTempo.mouseDown(with: event(.leftMouseDown, view: nextTempo))
    nextTempo.mouseDragged(with: event(.leftMouseDragged, view: nextTempo, x: 12))
    precondition(header.previewForTest != nil)
    header.needsDisplay = false
    let beforeCancellation = header.regionProjectionsForTest
    let redrawsBeforeCancellation = header.redrawRequestsForTest
    NativeTimelineInputGate.shared.setBlocked(true, for: window)
    precondition(header.redrawRequestsForTest == redrawsBeforeCancellation + 1 && header.regionProjectionsForTest == beforeCancellation + 1,
        "cancellation invalidates the retained preview pixels and commands")
    NativeTimelineInputGate.shared.setBlocked(false, for: window)
    nextTempo.mouseUp(with: event(.leftMouseUp, view: nextTempo))
    precondition(header.previewForTest == nil && moved.count == 1, "modal cancellation restores a local preview without committing")
    let text = NativeTimelineHeaderText.label("ÁÉção chorus", color: 0xffffff, scale: 2)!
    precondition(NativeTimelineHeaderText.label("ÁÉção chorus", color: 0xffffff, scale: 2) === text)
    let retina = NativeTimelineHeaderText.label("ÁÉção chorus", color: 0xffffff, scale: 1)!
    precondition(text.size == retina.size && text.image.width == retina.image.width * 2,
        "text images retain point size and change resolution only for backing scale")
    let huge = CGRect(x: 108_000_123, y: 0, width: 700, height: 240)
    // A region covering hours must still retain only viewport-sized geometry;
    // its offscreen name/identifier cannot become a document-sized bitmap.
    var longRegion = region; longRegion.endTime = 3600
    var distantMarker = section; distantMarker.position = Double(huge.minX + 100) / 81920
    song.parts = [longRegion]; song.markers = [distantMarker]
    header.configure(configuration())
    header.project(scale: 81920, viewport: huge, layoutWidth: 200_000_000, displayScale: 2)
    precondition(header.frame.origin == .zero && header.frame.width == 200_000_000 &&
        header.drawingForTest.frame.contains(huge) && header.drawingForTest.bounds.width <= 700 + 1536,
        "far-right maximum zoom keeps drawing bounded inside a stable document container")
    compareRetainedPixels(scale: 81920, offset: huge.minX, backing: 2, name: "far-right")
    func assertBounded(_ layer: CALayer) {
        precondition(layer.bounds.width.isFinite && layer.bounds.height.isFinite &&
            layer.bounds.width <= header.drawingForTest.bounds.width && layer.bounds.height <= header.drawingForTest.bounds.height,
            "retained layer backings stay within the prepared tile even at maximum zoom")
        precondition((layer.animationKeys() ?? []).isEmpty, "native zoom projections never start implicit animations")
        if let contents = layer.contents {
            let image = contents as! CGImage
            precondition(image.height <= 32 && image.width <= Int(header.drawingForTest.bounds.width * 2),
                "only small, unscaled label images own raster pixels")
        }
        if let mask = layer.mask { assertBounded(mask) }
        for child in layer.sublayers ?? [] { assertBounded(child) }
    }
    assertBounded(header.drawingForTest)
    precondition(header.retainedRegionsForTest.count == 1 && header.retainedMarkersForTest.count == 1 &&
        header.retainedBoundariesForTest.isEmpty, "offscreen nodes are removed rather than accumulating during pan")
    song.markers = []; song.parts = []
    header.configure(configuration()); header.project(scale: 10, viewport: viewport, layoutWidth: 100_000, displayScale: 2)
    precondition(header.markersForTest.isEmpty && header.identifiersForTest.isEmpty && header.markerForTest(tempo.id) == nil)
    precondition(header.retainedRegionsForTest.isEmpty && header.retainedMarkersForTest.isEmpty && header.retainedBoundariesForTest.isEmpty)
    header.configure(nil)
    print("NATIVE_HEADER_OK:1x/2x reference pixels, retained layer/image reuse, bounded geometry, region labels/colors, marker collision/input parity, captured drag and cancellation")
}
MainActor.assumeIsolated { runNativeHeaderTests() }

private final class HeaderTestDocument: NSView {
    override var isFlipped: Bool { true }
}
@MainActor private func headerResidentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    precondition(result == KERN_SUCCESS)
    return info.resident_size
}
@MainActor private func runWorldCoordinateHeaderTests() {
    let memoryBefore = headerResidentBytes()
    var peakMemory = memoryBefore
    for (name, scale, seconds, endDocument) in [
        ("six-hours", CGFloat(20), 21600.0, false),
        ("max-zoom-six-hours", CGFloat(81920), 21600.0, false),
        ("end-of-document", CGFloat(81920), 21600.0, true)
    ] {
        let world = seconds * scale
        let duration = 600.0 / scale
        let region = Part(id: UUID(), name: "Six hour region", startTime: seconds, endTime: seconds + duration, color: 0x705264)
        let marker = TimelineMarker(id: UUID(), name: "Late marker", position: seconds + 100 / scale, color: 0x40a050)
        let tempo = TimelineMarker(id: UUID(), name: "TEMPO", position: seconds + 350 / scale, color: 0x999999, tempoBPM: 120, tempoBeats: 4, tempoUnit: 4)
        let song = Song(id: UUID(), name: name, duration: seconds + duration, bpm: 120, tracks: [], parts: [region], markers: [marker, tempo])
        let width: CGFloat = endDocument ? world + 650 : world + 8192
        let offset: CGFloat = endDocument ? width - 700 : world - 50
        let window = NSWindow(contentRect: CGRect(x: -10000, y: 0, width: 700, height: 240), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 700, height: 240))
        scroll.drawsBackground = false
        let document = HeaderTestDocument(frame: CGRect(x: 0, y: 0, width: width, height: 240))
        scroll.documentView = document; window.contentView = scroll
        let header = NativeTimelineHeaderView(); document.addSubview(header)
        var edits: [UUID] = [], seeks: [UUID] = [], moves: [TimelineMarker] = [], regionEdits = 0
        var resizeEvents: [(CGFloat, Bool, Int)] = []
        let regionInput = RegionRightClick(edit: { regionEdits += 1 }, drag: { resizeEvents.append(($0, $1, $2)) })
        let config = NativeTimelineHeaderConfiguration(song: song, lanes: RegionLanes(parts: [region]), parentIDs: [],
            regionTargets: [.init(id: region.id, start: region.startTime, end: region.endTime, lane: 0,
                edgePadding: 10, selected: false, pinned: false, input: regionInput)],
            edit: { edits.append($0.id) }, delete: { _ in }, seek: { seeks.append($0.id) }, move: { moves.append($0) })
        header.configure(config)
        scroll.contentView.scroll(to: CGPoint(x: offset, y: 0)); scroll.reflectScrolledClipView(scroll.contentView)
        header.project(scale: scale, viewport: CGRect(x: offset, y: 0, width: 700, height: 240), layoutWidth: width, displayScale: 2)
        let stableFrame = header.frame, stableBounds = header.bounds
        let drawing = header.drawingForTest
        precondition(drawing.frame == header.tileForTest && drawing.bounds.width <= 2236)
        // Render through the document-sized backing root into a bounded tile.
        // This catches precision loss from large CALayer positions, as well as
        // accidental tile-local/world-coordinate mixing.
        func context() -> CGContext {
            let tile = header.tileForTest
            let pixelsWide = Int(tile.width * 2), pixelsHigh = Int(tile.height * 2)
            let result = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8,
                bytesPerRow: pixelsWide * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            result.translateBy(x: 0, y: CGFloat(pixelsHigh)); result.scaleBy(x: 2, y: -2)
            return result
        }
        let reference = context(); header.drawOriginalForTest(in: reference)
        let composite = context(); composite.translateBy(x: -header.tileForTest.minX, y: 0)
        header.layer!.render(in: composite)
        let original = reference.makeImage()!.dataProvider!.data! as Data
        let rendered = composite.makeImage()!.dataProvider!.data! as Data
        var totalDifference = 0, maxDifference = 0
        for index in original.indices {
            let delta = abs(Int(original[index]) - Int(rendered[index]))
            totalDifference += delta; maxDifference = max(maxDifference, delta)
        }
        precondition(maxDifference <= 1 && totalDifference <= 200,
            "root layer preserves distant-origin pixels exactly apart from original subpixel antialias: \(name), max=\(maxDifference), total=\(totalDifference)")
        print("FIXED_HEADER_WORLD_PIXELS \(name): max=\(maxDifference) total=\(totalDifference)")
        let ordinary = header.markerForTest(marker.id)!
        precondition(abs(ordinary.convert(ordinary.clickBounds.origin, to: document).x - (world + 100)) < 0.00001,
            "marker input remains in the same document position: \(name)")
        func event(_ type: NSEvent.EventType, view: NSView, point: CGPoint, delta: CGFloat = 0) -> NSEvent {
            var point = view.convert(point, to: nil); point.x += delta
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let click = CGPoint(x: ordinary.clickBounds.minX + 5, y: ordinary.clickBounds.minY + 5)
        precondition(ordinary.visibleRect.contains(click), "marker remains visible through a scrolled document: \(name)")
        precondition(RightClickRouter.shared.handle(event(.rightMouseDown, view: ordinary, point: click)),
            "real right-click router resolves the visible projected marker: \(name)")
        precondition(edits == [marker.id])
        ordinary.mouseDown(with: event(.leftMouseDown, view: ordinary, point: click))
        ordinary.mouseUp(with: event(.leftMouseUp, view: ordinary, point: click))
        precondition(seeks == [marker.id])
        precondition(header.markerForTest(tempo.id)?.drag == nil, "tempo markers inside songs retain their protected behavior")
        let moving = header.markerForTest(marker.id)!
        precondition(moving.drag != nil)
        let down = event(.leftMouseDown, view: moving, point: click)
        let initial = down.locationInWindow
        func markerEvent(_ type: NSEvent.EventType, delta: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: initial.x + delta, y: initial.y), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        moving.mouseDown(with: down)
        moving.mouseDragged(with: markerEvent(.leftMouseDragged, delta: 15.25))
        moving.mouseUp(with: markerEvent(.leftMouseUp, delta: 20.25))
        let expectedPosition = song.markerDragPosition(marker, to: marker.position + 20.25 / scale,
            pixelsPerSecond: scale, free: NSEvent.modifierFlags.contains(.shift))
        precondition(moves.count == 1 && abs(moves[0].position - expectedPosition) < 1e-9,
            "captured marker drag keeps exact document delta at distant origins: \(name)")
        header.configure(config)
        header.project(scale: scale, viewport: CGRect(x: offset, y: 0, width: 700, height: 240), layoutWidth: width, displayScale: 2)
        let regionView = header.regionViewForTest.subviews.compactMap { $0 as? RegionRightClickView }.first!
        let left = world - 8 - regionView.convert(.zero, to: document).x
        precondition(regionView.visibleRect.contains(CGPoint(x: left, y: 8)))
        let resizeDown = event(.leftMouseDown, view: regionView, point: CGPoint(x: left, y: 8))
        regionView.mouseDown(with: resizeDown)
        regionView.mouseDragged(with: event(.leftMouseDragged, view: regionView, point: CGPoint(x: left, y: 8), delta: 12))
        regionView.mouseUp(with: event(.leftMouseUp, view: regionView, point: CGPoint(x: left, y: 8), delta: 12))
        precondition(resizeEvents.count == 2 && resizeEvents.allSatisfy { $0.0 == 12 && $0.2 == -1 } && resizeEvents.last!.1,
            "region left-edge resize keeps correct cursor side and delta: \(name)")
        let right = region.endTime * scale + 8 - regionView.convert(.zero, to: document).x
        precondition(regionView.visibleRect.contains(CGPoint(x: right, y: 8)))
        regionView.mouseDown(with: event(.leftMouseDown, view: regionView, point: CGPoint(x: right, y: 8)))
        regionView.mouseDragged(with: event(.leftMouseDragged, view: regionView, point: CGPoint(x: right, y: 8), delta: -12))
        regionView.mouseUp(with: event(.leftMouseUp, view: regionView, point: CGPoint(x: right, y: 8), delta: -12))
        precondition(resizeEvents.count == 4 && resizeEvents.suffix(2).allSatisfy { $0.0 == -12 && $0.2 == 1 } && resizeEvents.last!.1,
            "region right-edge resize keeps correct cursor side and delta: \(name)")
        let menu = regionView.regionMenu(); let edit = menu.items.first!
        precondition(edit.target === regionView)
        _ = regionView.perform(edit.action!)
        precondition(regionEdits == 1, "region context-menu action still targets the same region: \(name)")
        let preparedStart = header.tileForTest.minX
        // Translation crosses buckets but cannot mutate either ancestor's AppKit geometry.
        for step in 0..<12 {
            let nextOffset = max(0, offset - CGFloat(step) * 512)
            header.project(scale: scale, viewport: CGRect(x: nextOffset, y: 0, width: 700, height: 240), layoutWidth: width, displayScale: 2)
            precondition(header.frame == stableFrame && header.bounds == stableBounds && header.regionViewForTest.frame == stableFrame,
                "prepared tile changes never move/resize header ancestors: \(name)")
            precondition(header.drawingForTest.bounds.width <= 2236 && header.drawingForTest.contents == nil && header.layer?.contents == nil,
                "document-sized containers have no raster contents: \(name)")
            header.displayIfNeeded(); header.layer?.displayIfNeeded()
        }
        precondition(header.tileForTest.minX < preparedStart)
        peakMemory = max(peakMemory, headerResidentBytes())
        window.close()
        print("FIXED_HEADER_WORLD_OK \(name): marker seek/drag/right-click, region resize/menu, fixed ancestors, bounded drawing")
    }
    precondition(peakMemory - memoryBefore < 64 * 1024 * 1024,
        "growing the empty container to 1.7 billion points must not allocate a document-sized bitmap")
    print("FIXED_HEADER_MEMORY deltaMiB=\(Double(peakMemory - memoryBefore) / 1048576)")
}
MainActor.assumeIsolated { runWorldCoordinateHeaderTests() }



private final class MarkerInputTestWindow: NSWindow {
    var keyForTest = true
    override var isKeyWindow: Bool { keyForTest }
}

@MainActor private func runMarkerInputMutationTests() {
    let window = MarkerInputTestWindow(contentRect: NSRect(x:-12000,y:0,width:700,height:240),styleMask:[.titled],backing:.buffered,defer:false)
    let document = NSView(frame:CGRect(x:0,y:0,width:1000000,height:240))
    window.contentView=document
    let header=NativeTimelineHeaderView();document.addSubview(header)
    var markers=(0..<100).map { TimelineMarker(id:UUID(),name:"Marker \($0)",position:Double($0)*4+5,color:0x40a050) }
    var song=Song(id:UUID(),name:"Marker input mutations",duration:5000,bpm:120,tracks:[],parts:[],markers:markers)
    var edits:[UUID]=[],deletes:[UUID]=[],seeks:[UUID]=[], editedNames:[String]=[]
    func configure() {
        header.configure(.init(song:song,lanes:RegionLanes(parts:[]),parentIDs:[],regionTargets:[],
            edit:{edits.append($0.id); editedNames.append($0.name)},delete:{deletes.append($0)},seek:{seeks.append($0.id)},move:{_ in}))
    }
    configure()
    var seen:[ObjectIdentifier:MarkerEditClickView]=[:], observers:[NSObjectProtocol]=[]
    var frameChanges=0
    func remember() {
        for marker in markers {
            guard let view=header.markerForTest(marker.id),seen[ObjectIdentifier(view)]==nil else {continue}
            seen[ObjectIdentifier(view)]=view;view.postsFrameChangedNotifications=true
            observers.append(NotificationCenter.default.addObserver(forName:NSView.frameDidChangeNotification,object:view,queue:nil){_ in frameChanges += 1})
        }
    }
    let viewport=CGRect(x:0,y:0,width:700,height:240)
    header.project(scale:1,viewport:viewport,layoutWidth:1000000,displayScale:2);remember()
    let initialCount=seen.count
    let initialSubviews=header.subviews.map(ObjectIdentifier.init)
    let initialLayers=seen.mapValues { $0.layer.map(ObjectIdentifier.init) }
    for iteration in 0..<160 {
        let scale=CGFloat([1,4,12,37,84,128][iteration%6])
        let left=CGFloat((iteration%5)*300)
        header.project(scale:scale,viewport:CGRect(x:left,y:0,width:700,height:240),layoutWidth:1000000,displayScale:2)
        remember()
    }
    for observer in observers {NotificationCenter.default.removeObserver(observer)}
    print("MARKER_MUTATIONS initial=\(initialCount) instances=\(seen.count) frameChanges=\(frameChanges)")
    precondition(header.subviews.map(ObjectIdentifier.init)==initialSubviews && seen.allSatisfy { initialLayers[$0.key] == $0.value.layer.map(ObjectIdentifier.init) },
        "input views and layers remain attached with unchanged identity after warmup")
    precondition(initialCount==100 && seen.count==100 && frameChanges==0,
        "zoom must not remount, move or resize marker inputs")
    precondition(seen.values.allSatisfy { $0.trackingAreas.isEmpty && $0.layer?.contents == nil },
        "marker inputs have no per-marker tracking or document-sized raster")
    header.updateTrackingAreas()
    precondition(header.trackingAreas.count==1,"one marker-band tracking area serves all targets")
    header.project(scale:10,viewport:viewport,layoutWidth:1000000,displayScale:2)
    let first=header.markerForTest(markers[0].id)!
    let rect=first.clickBounds
    precondition(window.isKeyWindow && !NativeTimelineInputGate.shared.isBlocked(window))
    NSCursor.arrow.set()
    func mouse(_ type:NSEvent.EventType,_ point:CGPoint,flags:NSEvent.ModifierFlags=[])->NSEvent {
        NSEvent.mouseEvent(with:type,location:header.convert(point,to:nil),modifierFlags:flags,timestamp:0,
            windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
    }
    let point=CGPoint(x:rect.midX,y:rect.midY)
    header.mouseMoved(with:mouse(.mouseMoved,point))
    precondition(NSCursor.current === NSCursor.resizeLeftRight,"native marker band sets move cursor")
    precondition(MarkerEditClickView.usesMoveCursor(for:mouse(.mouseMoved,point)))
    precondition(RightClickRouter.shared.handle(mouse(.rightMouseDown,point)))
    precondition(edits.last==markers[0].id)
    precondition(RightClickRouter.shared.handle(mouse(.leftMouseDown,point,flags:.option)))
    precondition(deletes.last==markers[0].id)
    header.project(scale:10,viewport:CGRect(x:20000,y:0,width:700,height:240),layoutWidth:1000000,displayScale:2)
    precondition(header.markerForTest(markers[0].id) === first && first.clickBounds.isNull)
    precondition(NSCursor.current === NSCursor.arrow,"stationary hovered marker culling clears move cursor")
    precondition(!MarkerEditClickView.usesMoveCursor(for:mouse(.mouseMoved,point)))
    precondition(!RightClickRouter.shared.handle(mouse(.rightMouseDown,point)),"inactive pooled input cannot steal old click")
    song.markers?[0].name = "Updated while pooled"; configure()
    header.project(scale:10,viewport:viewport,layoutWidth:1000000,displayScale:2)
    precondition(header.markerForTest(markers[0].id) === first)
    precondition(RightClickRouter.shared.handle(mouse(.rightMouseDown,point)) && editedNames.last == "Updated while pooled",
        "returning pooled input receives the latest immutable marker callback")
    header.mouseMoved(with:mouse(.mouseMoved,point))
    precondition(NSCursor.current === NSCursor.resizeLeftRight)
    window.keyForTest=false;NSCursor.pointingHand.set()
    header.mouseMoved(with:mouse(.mouseMoved,point))
    header.project(scale:10,viewport:CGRect(x:20000,y:0,width:700,height:240),layoutWidth:1000000,displayScale:2)
    precondition(NSCursor.current === NSCursor.pointingHand,"unfocused culling cannot change the active window cursor")
    window.keyForTest=true
    header.project(scale:10,viewport:viewport,layoutWidth:1000000,displayScale:2)
    header.mouseMoved(with:mouse(.mouseMoved,point))
    precondition(NSCursor.current === NSCursor.resizeLeftRight)
    song.markers?.removeAll{$0.id==markers[0].id};configure()
    precondition(NSCursor.current === NSCursor.arrow && header.markerForTest(markers[0].id)==nil,
        "structural deletion clears cursor before removing the hovered target")
    markers=(0..<500).map {TimelineMarker(id:UUID(),name:"Pool \($0)",position:Double($0)*5+5,color:0x40a050)}
    song.markers=markers;configure()
    for index in 0..<36 {
        header.project(scale:100,viewport:CGRect(x:CGFloat(index)*7000,y:0,width:700,height:240),layoutWidth:1000000,displayScale:2)
        let retained=markers.compactMap{header.markerForTest($0.id)}
        let inactive=retained.filter{$0.clickBounds.isNull}
        precondition(inactive.count<=128,"retained inactive marker input pool stays bounded")
    }
    print("MARKER_STABLE_INPUT_POOL_CURSOR_CULL_DELETE_OPTION_ROUTING_AND_NO_RASTER_OK")
    NSCursor.arrow.set()
    window.close()
}
MainActor.assumeIsolated { runMarkerInputMutationTests() }
