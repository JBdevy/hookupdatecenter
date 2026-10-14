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
    private struct Analysis { var sections: [Section] }
    private static func analyze(onsets: [Double], beatsPerBar: Int) -> Analysis {
        var times: [Double] = []
        for time in onsets.filter({ $0.isFinite && $0 >= 0 }).sorted() {
            if times.last.map({ time - $0 > 0.000001 }) ?? true { times.append(time) }
        }
        guard times.count >= 4 else { return Analysis(sections: []) }
        // A lone attack after the click has ended is not evidence of a new
        // tempo. Keep real rests (whole beat distances), but exclude an off-grid
        // tail after a stable clock before fitting: its endpoint otherwise
        // forces many false corrections throughout the preceding song.
        if times.count >= 10 {
            let tail = times.count - 1
            let recent = (tail - 8..<tail).map { times[$0] - times[$0 - 1] }.sorted()
            let period = (recent[3] + recent[4]) / 2
            let gap = times[tail] - times[tail - 1]
            let distance = gap / period
            let stable = recent.filter { abs($0 - period) <= period * 0.04 }.count >= 7
            if stable, distance > 1.5,
               abs(gap - distance.rounded() * period) > max(0.030, period * 0.05) {
                times.removeLast()
            }
        }
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
        // Attack variation is not a tempo change. Allow a small phase window
        // instead of adding markers to explain every millisecond of jitter.
        let periodChanges = zip(intervals.dropFirst(), intervals).map { abs($0 - $1) }.sorted()
        let tolerance = min(0.020, max(0.008, periodChanges[periodChanges.count / 2] * 2))
        // Estimate speed from several independent distances. Endpoints alone
        // confuse a rounded downbeat attack with a different clock frequency.
        // Long lags reject local attack noise; a bar lag compares like timbres.
        func integerTempo(first: Int, last: Int, anchoredTolerance: Double) -> Double? {
            let count = last - first + 1
            let half = (count - 1) / 2
            let lags = Set([max(1, half - 1), max(1, half), max(1, half + 1), max(1, beatsPerBar)])
            var slopes: [Double] = []
            for lag in lags where lag < count {
                for index in first...(last - lag) {
                    slopes.append((times[index + lag] - times[index]) / (beatPositions[index + lag] - beatPositions[index]))
                }
            }
            func median(_ values: [Double]) -> Double {
                let sorted = values.sorted(), middle = sorted.count / 2
                return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
            }
            guard !slopes.isEmpty else { return nil }
            let period = median(slopes), bpm = (60 / period).rounded()
            guard bpm >= 60, bpm <= 300 else { return nil }
            let deviation = median(slopes.map { abs($0 - period) })
            let beats = beatPositions[last] - beatPositions[first]
            // Tiny clock/attack measurement differences such as 130.001 are
            // not a distinct musical tempo. Still validate the full anchored
            // phase below so rounding cannot hide accumulated timing drift.
            let uncertainty = max(2 / 44100 / max(1, beats), 3 * deviation / sqrt(Double(count)))
            guard abs(60 / period - bpm) <= 0.01 || abs(period - 60 / bpm) <= uncertainty else { return nil }
            var phaseTolerance = anchoredTolerance
            if beatsPerBar > 0, beatsPerBar < count - 2 {
                let differences = (first...(last - beatsPerBar)).map { index in
                    abs(times[index + beatsPerBar] - times[index]
                        - (beatPositions[index + beatsPerBar] - beatPositions[index]) * 60 / bpm)
                }
                // A repeating attack offset can be larger than ordinary jitter.
                // Grant that window only when bar-to-bar phase is stable; ramps
                // must still be split rather than accumulating drift.
                if median(differences) <= 0.002 { phaseTolerance = max(phaseTolerance, 0.030) }
            }
            return (first...last).allSatisfy {
                abs(times[$0] - times[first] - (beatPositions[$0] - beatPositions[first]) * 60 / bpm) <= phaseTolerance
            } ? bpm : nil
        }
        var pending = [(first: 0, last: times.count - 1)]
        var sections: [Section] = []
        while let span = pending.popLast() {
            if Task.isCancelled { return Analysis(sections: []) }
            let first = span.first, last = span.last
            let beats = beatPositions[last] - beatPositions[first]
            let period = (times[last] - times[first]) / beats
            let measuredBPM = 60 / period
            let integerBPM = integerTempo(first: first, last: last, anchoredTolerance: tolerance)
            let integerFits = integerBPM != nil
            var maximumError = 0.0, split = first
            for index in first...last {
                let beat = beatPositions[index] - beatPositions[first]
                let elapsed = times[index] - times[first]
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
            let bpm = integerBPM ?? measuredBPM
            guard bpm.isFinite, bpm >= 60, bpm <= 300 else { continue }
            // Never merge merely because displayed/rounded BPMs match: a new
            // anchor can be essential to keep the next beats in phase.
            sections.append(Section(position: times[first], bpm: bpm))
        }
        // Merge attack-induced splits only while the complete merged span stays
        // within 20 ms of the measured clicks. Genuine ramps and short, distinct
        // changes keep their anchors; tiny local variations do not flood the grid.
        var merged: [Section] = []
        var index = 0
        while index < sections.count {
            let first = times.firstIndex(of: sections[index].position)!
            var lastSection = index
            var chosen = sections[index]
            while lastSection + 1 < sections.count {
                // A single delayed attack can give a very short span an
                // apparent change of several BPM. Validate measured phase,
                // not the extrema of those noisy per-span estimates.
                let last = lastSection + 2 < sections.count
                    ? times.firstIndex(of: sections[lastSection + 2].position)! : times.count - 1
                let bpm = 60 * (beatPositions[last] - beatPositions[first]) / (times[last] - times[first])
                func fits(_ value: Double) -> Bool {
                    value >= 60 && value <= 300 && (first...last).allSatisfy {
                        abs(times[$0] - times[first] - (beatPositions[$0] - beatPositions[first]) * 60 / value) <= 0.020
                    }
                }
                guard fits(bpm) else { break }
                if let integer = integerTempo(first: first, last: last, anchoredTolerance: 0.020), fits(integer) {
                    chosen.bpm = integer
                } else { chosen.bpm = bpm }
                lastSection += 1
            }
            merged.append(chosen); index = lastSection + 1
        }
        return Analysis(sections: merged)
    }

    /// Uses only the Click track inside this region. Imported projects and the
    /// manual Detect BPM action both require measured click evidence.
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
            : Analysis(sections: [])
        let sections = analysis.sections
        var markers = sections.enumerated().map { index, section in
            let end = index + 1 < sections.count ? sections[index + 1].position : region.endTime
            let detectedMeter = meter(transients: unique.filter { $0.position >= section.position && $0.position < end })
            let beats = detectedMeter?.beats ?? song.meterBeats
            let unit = detectedMeter?.unit ?? song.meterUnit
            let bpm = section.bpm
            return TimelineMarker(id: UUID(), name: "TEMPO", position: section.position, color: 0x999999,
                           tempoBPM: bpm, tempoBeats: beats,
                           tempoUnit: unit, tempoTimebase: .global, tempoReferenceBPM: bpm)
        }
        // The first audible click can follow a silent/count-in-free intro.
        // Protect that intro from the preceding song's tempo without moving
        // the measured first beat (which anchors both grid and metronome).
        if var initial = markers.first, initial.position > region.startTime {
            initial.id = UUID()
            initial.position = region.startTime
            markers.insert(initial, at: 0)
        }
        return (markers, hasClickAudio)
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
