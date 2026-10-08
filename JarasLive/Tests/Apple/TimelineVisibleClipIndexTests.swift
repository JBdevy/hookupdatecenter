import Foundation
import CoreGraphics

func expected(_ intervals: [(start: Double, end: Double)], from: Double, through: Double) -> [Int] {
    intervals.indices.filter { intervals[$0].start <= through && max(intervals[$0].start, intervals[$0].end) >= from }
}

@main enum TimelineVisibleClipIndexTests {
    static func main() {
        let overlap: [(start: Double, end: Double)] = [
            (80, 120), (0, 1000), (35, 60), (40, 42), (39, 41), (40, 40), (80, 110), (-40, -20)
        ]
        let index = TimelineVisibleClipIndex(intervals: overlap)
        for from in stride(from: -50.0, through: 1100, by: 0.75) {
            for length in [0.0, 0.5, 12, 50, 1000] {
                precondition(index.indices(from: from, through: from + length) == expected(overlap, from: from, through: from + length))
            }
        }
        precondition(index.indices(from: 40, through: 40) == [1, 2, 3, 4, 5], "same starts and spanning clips keep original drawing order")
        precondition(index.indices(from: 999, through: 1001) == [1], "a long clip remains visible far from its start")
        precondition(index.indices(from: 2, through: 1).isEmpty)
        precondition(index.indices(from: .nan, through: 100).isEmpty)
        precondition(TimelineVisibleClipIndex(intervals: []).indices(from: 0, through: 1).isEmpty)

        // An unsorted imported track and a deterministic set of crossing clips
        // check against a full scan over many viewport positions and sizes.
        var seed: UInt64 = 92
        func next() -> UInt64 { seed = seed &* 6364136223846793005 &+ 1; return seed }
        let shuffled = (0..<4096).map { _ -> (start: Double, end: Double) in
            let start = Double(next() % 200_000) / 10
            return (start, start + Double(next() % 12000) / 10)
        }
        let shuffledIndex = TimelineVisibleClipIndex(intervals: shuffled)
        for _ in 0..<1200 {
            let start = Double(next() % 210_000) / 10
            let end = start + Double(next() % 3000) / 10
            precondition(shuffledIndex.indices(from: start, through: end) == expected(shuffled, from: start, through: end))
        }

        // Minimum-width bodies can cross the viewport even with zero-duration
        // source intervals. Conservative pixel padding must not omit them at
        // any supported scale; exact CGRect culling still runs in the caller.
        let tiny = [(start: 4.0, end: 4.0), (start: 5.0, end: 5.000001)]
        let tinyIndex = TimelineVisibleClipIndex(intervals: tiny)
        let scales: [Double] = [0.0001, 0.1, 1, 10, 500, 1_000_000]
        func body(_ clip: (start: Double, end: Double), scale: Double) -> CGRect {
            let x = CGFloat(clip.start * scale + 1)
            let width = CGFloat(max(2.0, (clip.end - clip.start) * scale - 2))
            return CGRect(x: x, y: 0, width: width, height: 10)
        }
        for scale in scales {
            for clip in tiny {
                let rendered = body(clip, scale: scale)
                let viewport = CGRect(x: rendered.maxX - 0.25, y: 0, width: 10, height: 10)
                let candidates = tinyIndex.indices(from: Double(viewport.minX - 3) / scale, through: Double(viewport.maxX + 3) / scale)
                for item in tiny.indices {
                    let rect = body(tiny[item], scale: scale)
                    if rect.intersects(viewport) { precondition(candidates.contains(item)) }
                }
            }
        }

        // Prove ordinary sparse sessions do not scan all prior clips per frame.
        let longSession = (0..<100_000).map { (start: Double($0 * 4), end: Double($0 * 4 + 2)) }
        let largeIndex = TimelineVisibleClipIndex(intervals: longSession)
        let query = 350_000.0
        let range = largeIndex.candidateRange(from: query, through: query + 8)
        precondition(range.count == 3, "late viewport scans only its three candidates")
        precondition(largeIndex.indices(from: query, through: query + 8) == [87_500, 87_501, 87_502])
        print("TIMELINE_VISIBLE_CLIP_INDEX_OVERLAP_ORDER_RANDOM_PARITY_MINIMUM_PIXEL_WIDTH_BOUNDED_SCAN_OK")
    }
}
