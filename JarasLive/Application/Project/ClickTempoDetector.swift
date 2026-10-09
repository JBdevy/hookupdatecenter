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
    /// Follow measured click phase, including short changes and gradual ramps.
    /// All marker positions remain measured sample positions.
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
        // Build a piecewise tempo map whose *anchored phase*, not mean fit
        // error, follows every measured pulse. Adjacent spans share an onset,
        // so tempo ramps cannot silently accumulate drift between markers.
        // Clean clicks allow 1 ms; varying attack timbres allow up to 6 ms.
        let periodChanges = zip(intervals.dropFirst(), intervals).map { abs($0 - $1) }.sorted()
        let tolerance = min(0.006, max(0.001, periodChanges[periodChanges.count / 2] * 2))
        var pending = [(first: 0, last: times.count - 1)]
        var sections: [Section] = []
        while let span = pending.popLast() {
            if Task.isCancelled { return Analysis(sections: []) }
            let first = span.first, last = span.last
            let beats = beatPositions[last] - beatPositions[first]
            let period = (times[last] - times[first]) / beats
            let measuredBPM = 60 / period
            let integerBPM = measuredBPM.rounded()
            var integerFits = integerBPM >= 60 && integerBPM <= 300
            var maximumError = 0.0, split = first
            for index in first...last {
                let beat = beatPositions[index] - beatPositions[first]
                let elapsed = times[index] - times[first]
                if integerFits && abs(elapsed - beat * 60 / integerBPM) > tolerance { integerFits = false }
                let error = abs(elapsed - beat * period)
                if index > first && index < last && error > maximumError {
                    maximumError = error; split = index
                }
            }
            if !integerFits && maximumError > tolerance {
                // Process left first. Unlike a minimum four-pulse fit, this
                // preserves short changes and the beginning of an accelerando.
                pending.append((split, last))
                pending.append((first, split))
                continue
            }
            let bpm = integerFits ? integerBPM : measuredBPM
            guard bpm.isFinite, bpm >= 60, bpm <= 300 else { continue }
            // Never merge merely because displayed/rounded BPMs match: a new
            // anchor can be essential to keep the next beats in phase.
            sections.append(Section(position: times[first], bpm: bpm))
        }
        return Analysis(sections: sections)
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
            markers!.removeAll { $0.isTempo && $0.position >= region.startTime && $0.position < region.endTime }
        }
        for marker in detected {
            // A marker already at the onset is updated, never duplicated.
            if let index = markers!.firstIndex(where: { $0.isTempo && abs($0.position - marker.position) < 0.000001 }) {
                var replacement = marker; replacement.id = markers![index].id
                replacement = markerWithRegionOwnership(replacement)
                markers![index] = replacement
            } else { markers!.append(markerWithRegionOwnership(marker)) }
        }
        ensureInitialTempoMarker()
    }
}
