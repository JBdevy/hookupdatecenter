import Foundation

public enum TimelineTempo {
    public static let bpmRange = 60.0...300.0
    public static let beatUnits = [1, 2, 4, 8, 16, 32, 64]
    public static func gridStep(bar: Double, beats: Int, pixelsPerSecond: Double) -> Double {
        let width = bar * pixelsPerSecond
        if width > 28 { return bar / Double(beats) }
        return bar * pow(2, max(0, ceil(log2(4 / max(0.001, width)))))
    }
    public static func snap(_ time: Double, bar: Double, beats: Int, pixelsPerSecond: Double) -> Double {
        let step = gridStep(bar: bar, beats: beats, pixelsPerSecond: pixelsPerSecond)
        return max(0, (time / step).rounded() * step)
    }
    public static func snap<Anchors: Sequence>(_ time: Double, bar: Double, beats: Int,
                                               pixelsPerSecond: Double, anchors: Anchors,
                                               additionalAnchors: Anchors? = nil,
                                               cursor: Double? = nil, tolerancePixels: Double = 8) -> Double where Anchors.Element == Double {
        guard time.isFinite, pixelsPerSecond.isFinite, pixelsPerSecond > 0 else { return 0 }
        let position = max(0, time)
        let tolerance = max(0, tolerancePixels) / pixelsPerSecond
        var nearest: Double?
        var distance = tolerance
        for anchor in anchors where anchor.isFinite && anchor >= 0 {
            let delta = abs(anchor - position)
            if delta <= distance { nearest = anchor; distance = delta }
        }
        if let additionalAnchors {
            for anchor in additionalAnchors where anchor.isFinite && anchor >= 0 {
                let delta = abs(anchor - position)
                if delta < distance { nearest = anchor; distance = delta }
            }
        }
        if let cursor, cursor.isFinite, cursor >= 0, abs(cursor - position) < distance {
            nearest = cursor
        }
        return nearest ?? snap(position, bar: bar, beats: beats, pixelsPerSecond: pixelsPerSecond)
    }
}
public struct TapTempo {
    private var last: Double?
    private var intervals: [Double] = []
    public init() {}
    public mutating func tap(at time: Double) -> Double? {
        guard let previous = last, time > previous, time - previous <= 4 else {
            last = time; intervals.removeAll(keepingCapacity: true); return nil
        }
        let interval = time - previous
        guard interval >= 0.08 else { return nil }
        last = time
        intervals.append(interval)
        if intervals.count > 6 { intervals.removeFirst() }
        let bpm = 60 * Double(intervals.count) / intervals.reduce(0, +)
        return min(TimelineTempo.bpmRange.upperBound, max(TimelineTempo.bpmRange.lowerBound, (bpm * 10).rounded() / 10))
    }
}

public extension Song {
    mutating func followTempo(_ value: Double) {
        let speed = value / bpm, scale = 1 / speed
        duration *= scale
        for track in tracks.indices {
            for clip in tracks[track].clips.indices {
                let end = (tracks[track].clips[clip].startTime + tracks[track].clips[clip].duration) * scale
                tracks[track].clips[clip].startTime *= scale
                tracks[track].clips[clip].duration = end - tracks[track].clips[clip].startTime
                tracks[track].clips[clip].playbackRate = tracks[track].clips[clip].audioRate * speed
                if let offset = tracks[track].clips[clip].timecodeStartOffset { tracks[track].clips[clip].timecodeStartOffset = offset * scale }
                if let offset = tracks[track].clips[clip].timecodeEndOffset { tracks[track].clips[clip].timecodeEndOffset = offset * scale }
                duration = max(duration, tracks[track].clips[clip].startTime + tracks[track].clips[clip].duration)
            }
        }
        for part in parts.indices { parts[part].startTime *= scale; parts[part].endTime *= scale }
        if markers != nil { for index in markers!.indices { markers![index].position *= scale } }
        bpm = value
    }
}
