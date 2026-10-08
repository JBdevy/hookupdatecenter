MainActor.assumeIsolated {
    let trackCount = 200, clipsPerTrack = 250
    let ids = (0..<(trackCount * clipsPerTrack)).map { _ in UUID() }
    let lanes = (0..<trackCount).map { $0 % 3 + 1 }
    func geometry(_ height: CGFloat) -> (offsets: [CGFloat], heights: [CGFloat]) {
        let heights = lanes.map { $0 == 1 ? height : max(26, height * 0.7) }
        var running: CGFloat = 0
        let offsets = lanes.indices.map { i -> CGFloat in
            defer { running += CGFloat(lanes[i]) * heights[i] }
            return running
        }
        return (offsets, heights)
    }
    func items(_ geometry: (offsets: [CGFloat], heights: [CGFloat]), top: CGFloat) -> [GridSelectionItem] {
        ids.enumerated().map { index, id -> GridSelectionItem in
            let track = index / clipsPerTrack, local = index % clipsPerTrack, lane = local % lanes[track]
            let rect = CGRect(x: CGFloat(local / lanes[track]) * 12,
                              y: top + geometry.offsets[track] + CGFloat(lane) * geometry.heights[track] + 3,
                              width: 10, height: geometry.heights[track] - 6)
            return GridSelectionItem(id: id, rect: rect, name: "Audio \(index)",
                                     duration: 10, fadeIn: 0.5, trackIndex: track, laneIndex: lane)
        }
    }
    let cache = TimelineSelectionLayoutCache()
    var metadataBuilds = 0
    @MainActor func cached(_ height: CGFloat, top: CGFloat = 71, revision: Int = 1) -> GridSelectionLayout {
        let rows = geometry(height)
        return cache.layout(key: TimelineRenderKey(revision: revision), rowHeight: height, rulerHeight: top,
                            rowOffsets: rows.offsets, laneHeights: rows.heights) {
            metadataBuilds += 1
            return items(rows, top: top)
        }
    }
    let initial = cached(64)
    let initialStorage = initial.items.withUnsafeBufferPointer { $0.baseAddress }
    var projectedTimes: [Double] = [], rebuildTimes: [Double] = [], hits = 0
    for frame in 0..<50 {
        let height = CGFloat(24 + frame * 4)
        let top: CGFloat = frame % 2 == 0 ? 71 : 103
        let start = ProcessInfo.processInfo.systemUptime
        let projected = cached(height, top: top)
        let visible = CGRect(x: 250, y: 2100, width: 1100, height: 720)
        hits += projected.candidates(in: visible, pixelsPerSecond: 10).count
        projectedTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        precondition(projected.items.withUnsafeBufferPointer { $0.baseAddress } == initialStorage,
                     "height and ruler changes share all immutable item records")
        precondition(metadataBuilds == 1,"height changes must not enumerate every clip or rebuild metadata")

        // Compare production projection against a freshly built spatial index,
        // including overlapping lanes, distant rows, boundary hits and zoom.
        if frame % 7 == 0 {
            let geometry = geometry(height)
            let before = ProcessInfo.processInfo.systemUptime
            let rebuilt = GridSelectionLayout(items: items(geometry, top: top), timeCoordinates: true)
            rebuildTimes.append((ProcessInfo.processInfo.systemUptime - before) * 1000)
            for scale: CGFloat in [0.01, 1, 10, 317] {
                for track in [0, 1, 2, 17, 111, 199] {
                    for local in [0, 1, 18, 149, 249] {
                        let index = track * clipsPerTrack + local
                        let actual = projected.projectedItem(at: index, pixelsPerSecond: scale)
                        let expected = rebuilt.projectedItem(at: index, pixelsPerSecond: scale)
                        precondition(actual.rect == expected.rect && actual.name == expected.name && actual.fadeIn == expected.fadeIn)
                        precondition(projected.item(id: actual.id, pixelsPerSecond: scale)?.rect == expected.rect)
                        for hit in [CGRect(x: actual.rect.midX, y: actual.rect.midY, width: 0, height: 0),
                                    actual.rect.insetBy(dx: -4, dy: -1),
                                    CGRect(x: actual.rect.minX, y: actual.rect.maxY, width: 100, height: 26)] {
                            precondition(projected.candidates(in: hit, pixelsPerSecond: scale) == rebuilt.candidates(in: hit, pixelsPerSecond: scale),
                                         "hit testing and marquee candidates retain exact source/row/lane coordinates")
                        }
                    }
                }
            }
            precondition(projected.candidates(in: visible, pixelsPerSecond: 10) == rebuilt.candidates(in: visible, pixelsPerSecond: 10))
        }
        precondition(cached(height, top: top) === projected,"identical frames reuse the whole layout")
    }
    // Individual height changes keep the global row height and project key unchanged.
    var individual = geometry(64)
    individual.heights[17] = 91
    var offset: CGFloat = 0
    for index in lanes.indices {
        individual.offsets[index] = offset
        offset += CGFloat(lanes[index]) * individual.heights[index]
    }
    let individualLayout = cache.layout(key: TimelineRenderKey(revision: 1), rowHeight: 64, rulerHeight: 71,
                                       rowOffsets: individual.offsets, laneHeights: individual.heights) {
        metadataBuilds += 1; return items(individual, top: 71)
    }
    let rebuiltIndividual = GridSelectionLayout(items: items(individual, top: 71), timeCoordinates: true)
    precondition(metadataBuilds == 1 && individualLayout.items.withUnsafeBufferPointer { $0.baseAddress } == initialStorage)
    for track in [16, 17, 18, 111, 199] {
        let index = track * clipsPerTrack + 18
        let actual = individualLayout.projectedItem(at: index, pixelsPerSecond: 10)
        precondition(actual.rect == rebuiltIndividual.projectedItem(at: index, pixelsPerSecond: 10).rect)
        precondition(individualLayout.candidates(in: actual.rect, pixelsPerSecond: 10) == rebuiltIndividual.candidates(in: actual.rect, pixelsPerSecond: 10))
    }
    print("INDIVIDUAL_HEIGHT_50K_SHARED_METADATA_LANES_OFFSETS_HIT_TEST_OK")
    let sorted = projectedTimes.dropFirst(5).sorted(), baseline = rebuildTimes.sorted()
    print("HEIGHT_SELECTION_50K_PROJECT_MS median=\(sorted[sorted.count/2]) p95=\(sorted[Int(Double(sorted.count-1)*0.95)]) max=\(sorted.last!)")
    print("HEIGHT_SELECTION_50K_REBUILD_MS median=\(baseline[baseline.count/2]) metadataBuilds=\(metadataBuilds) hits=\(hits)")
    let edited = cached(64, revision: 2)
    precondition(metadataBuilds == 2 && edited.items.count == ids.count,"real project edits rebuild metadata exactly once")
    print("GRID_SELECTION_HEIGHT_INDEX_REUSE_EXACT_LANES_HIT_TEST_MARQUEE_ZOOM_REVISION_OK")
}
