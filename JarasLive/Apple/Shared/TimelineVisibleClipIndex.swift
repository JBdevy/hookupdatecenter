import Foundation

/// Immutable time-domain candidates for one track. A render snapshot builds
/// this once; zoom only changes the query bounds, never the stored intervals.
/// Prefix maxima preserve clips that start long before the visible interval.
struct TimelineVisibleClipIndex {
    private struct Entry {
        let sourceIndex: Int
        let start: Double
        let end: Double
    }
    private let entries: [Entry]
    private let prefixEnd: [Double]

    init(intervals: [(start: Double, end: Double)]) {
        entries = intervals.enumerated().compactMap { index, interval in
            guard interval.start.isFinite, !interval.end.isNaN else { return nil }
            return Entry(sourceIndex: index, start: interval.start,
                         end: max(interval.start, interval.end))
        }.sorted { lhs, rhs in
            lhs.start == rhs.start ? lhs.sourceIndex < rhs.sourceIndex : lhs.start < rhs.start
        }
        var maximum = -Double.infinity
        prefixEnd = entries.map { entry in
            maximum = max(maximum, entry.end)
            return maximum
        }
    }

    /// Inclusive candidates, in original clip order so overlapping item paint
    /// order stays unchanged. Callers retain their exact pixel intersection.
    func indices(from start: Double, through end: Double) -> [Int] {
        guard !start.isNaN, !end.isNaN, start <= end, !entries.isEmpty else { return [] }
        let range = candidateRange(from: start, through: end)
        guard !range.isEmpty else { return [] }
        var result: [Int] = []
        result.reserveCapacity(min(range.count, 32))
        for index in range where entries[index].end >= start {
            result.append(entries[index].sourceIndex)
        }
        // Most projects already have chronological clip arrays, but imports,
        // moves and overlapping recordings can give them a different order.
        result.sort()
        return result
    }

    /// Visible portions of a stacked item. More recent paint order wins,
    /// independent of the playback order used to mix overlapping audio.
    func uncoveredParts(start: Double, end: Double, above sourceIndex: Int,
                        interval: (Int) -> (Double, Double)) -> [Range<Double>]? {
        let covers = indices(from: start, through: end)
            .filter { $0 > sourceIndex }
            .map(interval)
            .filter { $0.0 < end && $0.1 > start }
            .sorted { $0.0 < $1.0 }
        if covers.isEmpty { return nil }
        var remaining: [Range<Double>] = []
        var left = start
        for (first, last) in covers where last > left {
            let right = min(first, end)
            if right > left { remaining.append(left..<right) }
            left = max(left, last)
            if left >= end { return remaining }
        }
        remaining.append(left..<end)
        return remaining
    }

    /// Exposed internally for work-bound tests without adding per-frame clocks
    /// or counters to the renderer.
    func candidateRange(from start: Double, through end: Double) -> Range<Int> {
        guard !start.isNaN, !end.isNaN, start <= end else { return 0..<0 }
        var low = 0, high = entries.count
        while low < high {
            let middle = low + (high - low) / 2
            if entries[middle].start <= end { low = middle + 1 } else { high = middle }
        }
        let upper = low
        low = 0; high = upper
        while low < high {
            let middle = low + (high - low) / 2
            if prefixEnd[middle] < start { low = middle + 1 } else { high = middle }
        }
        return low..<upper
    }
}

/// Track rows are contiguous and ordered by their document offsets. Find the
/// visible range without walking every track for each new scroll or zoom tile.
func timelineRowsIntersecting(_ visible: ClosedRange<CGFloat>, offsets: [CGFloat],
                              heights: [CGFloat], top: CGFloat) -> Range<Int> {
    var low = 0, high = offsets.count
    while low < high {
        let mid = low + (high - low) / 2
        if top + offsets[mid] + heights[mid] < visible.lowerBound { low = mid + 1 }
        else { high = mid }
    }
    let first = low
    high = offsets.count
    while low < high {
        let mid = low + (high - low) / 2
        if top + offsets[mid] <= visible.upperBound { low = mid + 1 }
        else { high = mid }
    }
    return first..<low
}

func timelineTrackSeparators(in visible: ClosedRange<CGFloat>, offsets: [CGFloat],
                             heights: [CGFloat], top: CGFloat) -> [CGFloat] {
    var boundaries: [CGFloat] = []
    for row in timelineRowsIntersecting(visible, offsets: offsets, heights: heights, top: top) where heights[row] > 0 {
        let start = top + offsets[row]
        for boundary in [start, start + heights[row]] where visible.contains(boundary) && boundaries.last != boundary {
            boundaries.append(boundary)
        }
    }
    return boundaries
}
