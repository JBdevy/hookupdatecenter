import Foundation

/// Visible loop seams, with no scan through repetitions outside the viewport.
public struct ClipRepetitionBoundaries: Sequence {
    public struct Iterator: IteratorProtocol {
        var position: Double
        let end: Double
        let step: Double
        public mutating func next() -> Double? {
            guard position <= end else { return nil }
            let value = position
            let next = position + step
            position = next > position ? next : .infinity
            return value
        }
    }
    private let first: Double
    private let end: Double
    private let step: Double
    public init(clip: AudioClip, visible: ClosedRange<Double>, minimumSpacing: Double = 0) {
        guard let length = clip.loopLength, length.isFinite, length > 0,
              clip.audioRate.isFinite, clip.audioRate > 0 else {
            first = 1; end = 0; step = 1; return
        }
        let interval = length / clip.audioRate
        let offset = clip.sourceOffset - (clip.loopStart ?? 0)
        let phase = ((offset.truncatingRemainder(dividingBy: length) + length).truncatingRemainder(dividingBy: length))
        let origin = clip.startTime + (length - phase) / clip.audioRate
        let firstIndex = Swift.max(0, ceil((Swift.max(visible.lowerBound, clip.startTime + 0.000001) - origin) / interval))
        let skip = Swift.max(1, ceil(Swift.max(0, minimumSpacing) / interval))
        first = origin + ceil(firstIndex / skip) * skip * interval
        end = Swift.min(visible.upperBound, clip.startTime + clip.duration - 0.000001)
        step = interval * skip
    }
    public func makeIterator() -> Iterator { Iterator(position: first, end: end, step: step) }
}
