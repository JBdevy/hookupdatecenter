import Foundation

public enum ClickTempoDetector {
    public struct Section: Equatable, Sendable {
        public var position: Double
        public var bpm: Double
        public init(position: Double, bpm: Double) { self.position = position; self.bpm = bpm }
    }
    /// Click onsets are already sample accurate. Stable interval runs preserve
    /// the first beat of a tempo change, instead of the beat that confirmed it.
    public static func sections(onsets: [Double]) -> [Section] {
        let times = onsets.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard times.count >= 4 else { return [] }
        let intervals = zip(times.dropFirst(), times).map(-)
        var result: [Section] = [], index = 0
        while index + 2 < intervals.count {
            let window = Array(intervals[index...index + 2]).sorted()
            let period = window[1]
            guard (0.2...1.0).contains(period), window.allSatisfy({ abs($0 - period) < max(0.003, period * 0.025) }) else { index += 1; continue }
            let firstBeat = index
            var periods = Array(intervals[index...index + 2])
            index += 3
            while index < intervals.count {
                let ratio = intervals[index] / period
                // A missing beat must not create a false half-tempo section.
                if abs(ratio - ratio.rounded()) <= 0.025 && ratio >= 0.975 && ratio <= 4.025 {
                    periods.append(intervals[index] / max(1, ratio.rounded())); index += 1
                } else { break }
            }
            periods.sort()
            let measured = periods[periods.count / 2]
            let bpm = min(300, max(60, 60 / measured))
            if let previous = result.last, abs(previous.bpm - bpm) <= max(0.5, bpm * 0.025) {
                // MP3 pre-echo and unequal click attacks perturb the first few
                // intervals. A longer agreeing run refines BPM without inventing
                // a tempo marker or changing the original first-click position.
                if periods.count >= 6 { result[result.count - 1].bpm = bpm }
            } else { result.append(Section(position: times[firstBeat], bpm: bpm)) }

        }
        // Keep full detection precision while comparing runs; only the final
        // tempo written to a marker is rounded to a whole BPM.
        return result.map { Section(position: $0.position, bpm: $0.bpm.rounded()) }
    }

    /// Uses only the Click track inside this region. Imported projects and the
    /// manual Detect BPM action share the same placement and fallback rules.
    public static func markers(song: Song, region: Part, onsetsFor: (AudioFile) throws -> [Double]) throws -> (markers: [TimelineMarker], hasClickAudio: Bool) {
        var times: [Double] = []
        var hasClickAudio = false
        for track in song.tracks where track.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("click") == .orderedSame || track.role == .click {
            for clip in track.clips where clip.startTime < region.endTime && clip.startTime + clip.duration > region.startTime {
                if region.parentRegionID != nil && clip.startTime < region.startTime { continue }
                guard let file = clip.audioFile ?? track.audioFile else { continue }
                hasClickAudio = true
                for onset in try onsetsFor(file) {
                    let position = clip.startTime + (onset - clip.sourceOffset) / clip.audioRate
                    if position >= max(clip.startTime, region.startTime), position < min(clip.startTime + clip.duration, region.endTime) {
                        times.append(position)
                    }
                }
            }
        }
        var unique: [Double] = []
        for time in times.sorted() where unique.last.map({ time - $0 > 0.08 }) ?? true { unique.append(time) }
        let sections = hasClickAudio ? self.sections(onsets: unique) : [Section(position: region.startTime, bpm: 120)]
        return (sections.map { section in
            TimelineMarker(id: UUID(), name: "TEMPO", position: section.position, color: 0x999999,
                           tempoBPM: section.bpm, tempoBeats: hasClickAudio ? song.meterBeats : 4,
                           tempoUnit: hasClickAudio ? song.meterUnit : 4, tempoTimebase: .global)
        }, hasClickAudio)
    }
}
