import Foundation

public enum ClickTempoDetector {
    public struct Section: Equatable, Sendable {
        public var position: Double
        public var bpm: Double
        public init(position: Double, bpm: Double) { self.position = position; self.bpm = bpm }
    }
    public struct Transient: Equatable, Sendable {
        public var position: Double
        public var peak: Double
        public var shape: [Double]
        public init(position: Double, peak: Double = 1, shape: [Double] = []) {
            self.position = position; self.peak = peak; self.shape = shape
        }
    }
    public struct Meter: Equatable, Sendable {
        public let beats: Int
        public let unit: Int
    }
    /// Infer the shortest repeating A–B pattern only when at least three bars
    /// agree. A may be quieter or a different timbre, not just a louder accent.
    public static func meter(transients: [Transient]) -> Meter? {
        let pulses = transients.filter { $0.peak.isFinite && $0.peak > 0 && $0.shape.allSatisfy(\.isFinite) }
        guard pulses.count >= 6 else { return nil }
        let dimensions = pulses.map { $0.shape.count }.min() ?? 0
        let features = pulses.map { [log2(max(0.000001, $0.peak))] + Array($0.shape.prefix(dimensions)) }
        func average(_ values: [[Double]]) -> [Double] {
            (0...dimensions).map { d in values.reduce(0) { $0 + $1[d] } / Double(values.count) }
        }
        func distance(_ a: [Double], _ b: [Double]) -> Double {
            sqrt(zip(a,b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) })
        }
        for period in 2...12 where pulses.count >= period * 3 {
            for phase in 0..<period {
                let accented = features.indices.filter { $0 % period == phase }.map { features[$0] }
                let ordinary = features.indices.filter { $0 % period != phase }.map { features[$0] }
                let a = average(accented), b = average(ordinary), contrast = distance(a,b)
                guard contrast >= 0.2 else { continue }
                let tolerance = max(0.08, contrast * 0.35)
                guard Double(accented.filter({ distance($0,a) <= tolerance }).count) / Double(accented.count) >= 0.9,
                      Double(ordinary.filter({ distance($0,b) <= tolerance }).count) / Double(ordinary.count) >= 0.9 else { continue }
                return Meter(beats: period, unit: 4)
            }
        }
        return nil
    }
    /// Confirm a tempo with three intervals, but anchor it to the first onset
    /// of that run. All marker positions remain measured sample positions.
    public static func sections(onsets: [Double], beatsPerBar: Int = 4) -> [Section] {
        analyze(onsets: onsets, beatsPerBar: beatsPerBar).sections
    }
    private struct Analysis { var sections: [Section]; var variable = false }
    private static func analyze(onsets: [Double], beatsPerBar: Int) -> Analysis {
        var times: [Double] = []
        for time in onsets.filter({ $0.isFinite && $0 >= 0 }).sorted() {
            if times.last.map({ time - $0 > 0.000001 }) ?? true { times.append(time) }
        }
        guard times.count >= 4 else { return Analysis(sections: []) }
        let intervals = zip(times.dropFirst(), times).map(-)
        // Assign missing clicks their beat distance using neighboring intervals.
        // A sustained half/double tempo remains one beat per pulse, while an
        // isolated missing click takes two beats. No onset is quantized or moved.
        var beatPositions = [0.0]
        for index in intervals.indices {
            let nearby = Array(intervals[max(0, index - 3)...min(intervals.count - 1, index + 3)]).sorted()
            let median = nearby[nearby.count / 2]
            let multiple = median > 0 ? (intervals[index] / median).rounded() : 1
            let missing = multiple >= 2 && multiple <= 4 && abs(intervals[index] - multiple * median) < max(0.012, median * 0.03)
            beatPositions.append(beatPositions.last! + (missing ? multiple : 1))
        }
        // Least-squares fits use prefix sums, so testing a boundary is constant
        // time. This measures a run of clicks instead of mistaking alternating
        // attacks / MP3 pre-echo for a new rate at every few pulses.
        struct Fit { var period: Double; var intercept: Double; var error: Double }
        var sx = [0.0], sy = [0.0], sxx = [0.0], sxy = [0.0], syy = [0.0]
        for index in times.indices {
            let x = beatPositions[index], y = times[index] - times[0]
            sx.append(sx.last! + x); sy.append(sy.last! + y)
            sxx.append(sxx.last! + x*x); sxy.append(sxy.last! + x*y); syy.append(syy.last! + y*y)
        }
        func fit(_ first: Int, _ last: Int) -> Fit {
            let count = last - first + 1, n = Double(count), end = last + 1
            let x = sx[end] - sx[first], y = sy[end] - sy[first]
            let xx = max(0.000001, sxx[end] - sxx[first] - x*x/n)
            let xy = sxy[end] - sxy[first] - x*y/n
            let yy = syy[end] - syy[first] - y*y/n
            return Fit(period: xy/xx, intercept: (y - xy/xx*x)/n, error: max(0, yy - xy*xy/xx))
        }
        let whole = fit(0, times.count - 1)
        if whole.period >= 0.2 - 0.002, whole.period <= 1 + 0.002,
           times.indices.allSatisfy({ abs(times[$0] - times[0] - (whole.intercept + whole.period * beatPositions[$0])) <= 0.006 }) {
            return Analysis(sections: [Section(position: times[0], bpm: min(300, max(60, (60 / whole.period).rounded())))])
        }
        // Penalized change-point search. Pruning is delayed by the minimum
        // run length so short sections cannot incorrectly discard a candidate.
        let minimum = 4, penalty = 0.006 * 0.006 * 12
        let count = times.count
        var costs = [Double](repeating: .infinity, count: count + 1)
        var previous = [Int](repeating: -1, count: count + 1)
        var candidates: [(start: Int, expires: Int)] = [(0, Int.max)]
        costs[0] = -penalty
        var errors: [Double] = []
        for end in minimum...count {
            if end % 256 == 0 && Task.isCancelled { return Analysis(sections: []) }
            let start = end - minimum
            if start > 0, costs[start].isFinite { candidates.append((start, Int.max)) }
            candidates.removeAll { $0.expires < end }
            errors.removeAll(keepingCapacity: true)
            errors.reserveCapacity(candidates.count)
            for candidate in candidates {
                let cost = costs[candidate.start] + fit(candidate.start, end - 1).error
                errors.append(cost)
                if cost + penalty < costs[end] { costs[end] = cost + penalty; previous[end] = candidate.start }
            }
            for index in candidates.indices where errors[index] > costs[end] + 0.000000001 {
                candidates[index].expires = min(candidates[index].expires, end + minimum)
            }
        }
        struct Run { var first: Int; var last: Int; var fit: Fit }
        var runs: [Run] = [], end = count
        while previous[end] >= 0 {
            let start = previous[end]
            runs.append(Run(first: start, last: end - 1, fit: fit(start, end - 1)))
            end = start
        }
        runs.reverse()
        var rounded: [Section] = []
        var sectionBeats: [Double] = []
        for (index, run) in runs.enumerated() {
            guard run.fit.period >= 0.2 - 0.002, run.fit.period <= 1 + 0.002,
                  sqrt(run.fit.error / Double(run.last - run.first + 1)) <= 0.025 else { continue }
            let bpm = min(300, max(60, (60 / run.fit.period).rounded()))
            if rounded.last?.bpm == bpm { continue }
            var first = run.first
            if index > 0 {
                let before = runs[index - 1]
                let delta = before.fit.period - run.fit.period
                if abs(delta) > 0.000001 {
                    let crossing = (run.fit.intercept - before.fit.intercept) / delta
                    // Fits identify the boundary; the actual sampled onset is
                    // the marker. Never place it between pulses or on their peak.
                    if abs(beatPositions[before.last] - crossing) < abs(beatPositions[first] - crossing) { first = before.last }
                }
            }
            rounded.append(Section(position: times[first], bpm: bpm))
            sectionBeats.append(beatPositions[first])
        }
        // An isolated short section is valid. Fall back only after a sequence
        // of three consecutive short tempo spans (four distinct tempo sections),
        // each changing again within two bars. Longer stable spans reset it.
        // Count measured beats rather than rounded BPM so e.g. 119.6 → 120
        // cannot turn exactly two bars into slightly more than two bars.
        var consecutiveShortSpans = 0
        for index in sectionBeats.indices.dropFirst() {
            let beats = sectionBeats[index] - sectionBeats[index - 1]
            if beats <= Double(max(1, beatsPerBar) * 2) + 0.000001 {
                consecutiveShortSpans += 1
            } else { consecutiveShortSpans = 0 }
            if consecutiveShortSpans >= 3 {
                return Analysis(sections: [Section(position: times[0], bpm: 120)], variable: true)
            }
        }
        return Analysis(sections: rounded)
    }

    /// Uses only the Click track inside this region. Imported projects and the
    /// manual Detect BPM action share the same placement and fallback rules.
    public static func markers(song: Song, region: Part, onsetsFor: (AudioFile) throws -> [Double]) throws -> (markers: [TimelineMarker], hasClickAudio: Bool) {
        try markersWithMeter(song: song, region: region, transientsFor: { file in
            try onsetsFor(file).map { Transient(position: $0) }
        })
    }
    public static func markersWithMeter(song: Song, region: Part, transientsFor: (AudioFile) throws -> [Transient]) throws -> (markers: [TimelineMarker], hasClickAudio: Bool) {
        // Analyze a private Free Grid snapshot; never publish a temporary mode.
        var song = song
        var timing = song.projectTime; timing.timebase = .free
        song.timeSettings = timing
        var pulses: [Transient] = []
        var hasClickAudio = false
        for track in song.tracks where track.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("click") == .orderedSame || track.role == .click {
            for clip in track.clips where clip.startTime < region.endTime && clip.startTime + clip.duration > region.startTime {
                if region.parentRegionID != nil && clip.startTime < region.startTime { continue }
                guard let file = clip.audioFile ?? track.audioFile else { continue }
                hasClickAudio = true
                for pulse in try transientsFor(file) {
                    let position = clip.startTime + (pulse.position - clip.sourceOffset) / clip.audioRate
                    if position >= max(clip.startTime, region.startTime), position < min(clip.startTime + clip.duration, region.endTime) {
                        var shifted = pulse; shifted.position = position; pulses.append(shifted)
                    }
                }
            }
        }
        var unique: [Transient] = []
        for pulse in pulses.sorted(by: { $0.position < $1.position }) where unique.last.map({ pulse.position - $0.position > 0.08 }) ?? true { unique.append(pulse) }
        let analysis = hasClickAudio ? analyze(onsets: unique.map(\.position), beatsPerBar: meter(transients: unique)?.beats ?? song.meterBeats)
            : Analysis(sections: [Section(position: region.startTime, bpm: 120)], variable: true)
        let sections = analysis.sections
        return (sections.enumerated().map { index, section in
            let end = index + 1 < sections.count ? sections[index + 1].position : region.endTime
            let detectedMeter = analysis.variable ? Meter(beats: 4, unit: 4) : meter(transients: unique.filter { $0.position >= section.position && $0.position < end })
            let beats = detectedMeter?.beats ?? (hasClickAudio ? song.meterBeats : 4)
            let unit = 4
            let bpm = section.bpm
            return TimelineMarker(id: UUID(), name: "TEMPO", position: section.position, color: 0x999999,
                           tempoBPM: bpm, tempoBeats: beats,
                           tempoUnit: unit, tempoTimebase: .global, tempoReferenceBPM: bpm)
        }, hasClickAudio)
    }
}

public extension Song {
    mutating func insertDetectedTempo(_ detected: [TimelineMarker], replacing region: Part? = nil) {
        let original = timeSettings
        defer { timeSettings = original }
        var timing = projectTime; timing.timebase = .free; timeSettings = timing
        if markers == nil { markers = [] }
        if let region {
            markers!.removeAll { $0.isTempo && $0.tempoReferenceBPM != nil && $0.position >= region.startTime && $0.position < region.endTime }
        }
        for marker in detected {
            // A marker already at the onset is updated, never duplicated.
            if let index = markers!.firstIndex(where: { $0.isTempo && abs($0.position - marker.position) < 0.000001 }) {
                var replacement = marker; replacement.id = markers![index].id; markers![index] = replacement
            } else { markers!.append(marker) }
        }
        ensureInitialTempoMarker()
    }
}
