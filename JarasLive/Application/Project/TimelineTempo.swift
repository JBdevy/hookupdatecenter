import Foundation

public struct ItemRateSettings: Equatable, Sendable {
    public let baseBPM: Double
    public var rate: Double
    private var rateStepOrigin: Double?
    private var lastSteppedRate: Double?
    private var rateSteps = 0
    public init(baseBPM: Double, rate: Double = 1) { self.baseBPM = baseBPM > 0 && baseBPM.isFinite ? baseBPM : 120; self.rate = rate }
    public var bpmOffset: Double {
        get { baseBPM * (rate - 1) }
        set { rate = (baseBPM + newValue) / baseBPM; rateStepOrigin = nil }
    }
    public var isValid: Bool { rate.isFinite && (1.0 / 32...32).contains(rate) }
    public var rateText: String {
        var text = String(rate)
        guard !text.lowercased().contains("e"), rate.isFinite else { return text }
        if !text.contains(".") { text += "." }
        let decimals = text.split(separator: ".", omittingEmptySubsequences: false).last?.count ?? 0
        text += String(repeating: "0", count: max(0, 6 - decimals))
        return text
    }
    public mutating func stepRate(_ count: Int) {
        if rateStepOrigin == nil || lastSteppedRate != rate { rateStepOrigin = rate; rateSteps = 0 }
        rateSteps += count; rate = rateStepOrigin! + Double(rateSteps) / 100; lastSteppedRate = rate
    }
    public mutating func stepBPM(_ count: Int) { bpmOffset += Double(count) }
    public mutating func reset() { rate = 1; rateStepOrigin = nil }
}

/// Item names expose the same source speed used by the playback fragments.
/// A range describes items crossing several tempo sections without claiming
/// that the entire item plays at its first section's rate.
public enum TimelineItemMediaTitle {
    public static func title(_ name: String, path: String?) -> String {
        guard let path else { return name }
        let ext = (path.replacingOccurrences(of: "\\", with: "/") as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return name }
        if name.lowercased().hasSuffix(" - " + ext) { return name }
        let base = name.lowercased().hasSuffix("." + ext) ? String(name.dropLast(ext.count + 1)) : name
        return base + " - " + ext
    }
}

public enum TimelineItemPlaybackRate {
    public static func title(_ name: String, rates: [Double], referenceRate: Double = 1) -> String {
        let values = rates.filter { $0.isFinite && $0 > 0 }
        guard let low = values.min(), let high = values.max(),
              values.contains(where: { abs($0 - referenceRate) > 0.0000005 }) else { return name }
        func formatted(_ rate: Double) -> String {
            var result = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), rate)
            while result.last == "0" { result.removeLast() }
            if result.last == "." { result.removeLast() }
            return result
        }
        let first = formatted(low), last = formatted(high)
        guard first != "1" || last != "1" else { return name }
        return "[\(first == last ? first : first + "–" + last)] \(name)"
    }
}

public enum ProjectTimebase: String, Codable, CaseIterable, Sendable {
    case free, relative
    public var title: String { self == .free ? "Free Grid" : "Relative Grid" }
}
public enum TempoMarkerTimebase: String, Codable, CaseIterable, Sendable {
    case global, free, relative
    public var title: String {
        switch self {
        case .global: return "Global"
        case .free: return "Free"
        case .relative: return "Relative"
        }
    }
    public func resolved(project: ProjectTimebase) -> ProjectTimebase {
        switch self {
        case .global: return project
        case .free: return .free
        case .relative: return .relative
        }
    }
}
public struct ProjectTimeSettings: Codable, Equatable, Sendable {
    public var divisions = 4
    public var timebase: ProjectTimebase = .relative
    public var affectsMIDIItems = false
    public var affectsAutomationLength = true
    public init() {}
    public static var legacy: Self { var value = Self(); value.timebase = .free; return value }
    public func validate() throws {
        guard [0, 2, 4, 8].contains(divisions) else { throw ProjectError.invalid("Invalid grid divisions") }
    }
}

public enum TimelineTempo {
    public static let bpmRange = 60.0...300.0
    public static let beatUnits = [1, 2, 4, 8, 16, 32, 64]
    public static let minimumGridSpacing = 16.0
    public static func barStride(bar: Double, pixelsPerSecond: Double) -> Int {
        Int(pow(2, max(0, ceil(log2((minimumGridSpacing / 2) / max(0.001, bar * pixelsPerSecond))))))
    }
    /// Number the same bar starts used by the timeline grid, continuing across
    /// tempo and meter changes. A marker starts a new bar even mid-measure.
    public static func visibleBars(in sections: [TimelineTempoSection], from visibleStart: Double,
                                   to visibleEnd: Double, pixelsPerSecond: Double) -> [(time: Double, number: Int)] {
        guard pixelsPerSecond > 0, visibleEnd >= visibleStart else { return [] }
        var firstNumber = 1
        var result: [(time: Double, number: Int)] = []
        for section in sections {
            let bar = section.barSeconds
            guard bar > 0, section.end > section.start else { continue }
            let count = max(0, Int(ceil((section.end - section.start) / bar - 1e-9)))
            defer { firstNumber += count }
            guard section.end >= visibleStart, section.start <= visibleEnd else { continue }
            // Labels need more room than a line; keep their real numbers when
            // some are skipped at distant zoom levels.
            let strideBars = max(1, barStride(bar: bar, pixelsPerSecond: pixelsPerSecond),
                                 Int(pow(2, max(0, ceil(log2(32 / max(0.001, bar * pixelsPerSecond)))))))
            let first = max(0, Int(floor((visibleStart - section.start) / bar)) / strideBars * strideBars)
            let last = min(count - 1, max(first, Int(ceil((visibleEnd - section.start) / bar))))
            guard first <= last else { continue }
            for index in stride(from: first, through: last, by: strideBars) {
                let time = section.start + Double(index) * bar
                if time >= visibleStart, time <= visibleEnd, time < section.end {
                    result.append((time, firstNumber + index))
                }
            }
        }
        return result
    }
    public static func gridStep(bar: Double, beats: Int, pixelsPerSecond: Double, divisions: Int? = nil, unit: Int = 4) -> Double {
        if divisions == 0 { return 0 }
        let beat = bar / Double(beats)
        let base = min(beat, beat * Double(unit) / Double(divisions ?? unit))
        let step = base * pow(2, max(0, ceil(log2(minimumGridSpacing / max(0.001, base * pixelsPerSecond)))))
        // Reveal groups of beats before every beat fits on screen.
        return step < bar ? step : bar * Double(barStride(bar: bar, pixelsPerSecond: pixelsPerSecond))
    }
    public static func snap(_ time: Double, bar: Double, beats: Int, pixelsPerSecond: Double, divisions: Int? = nil, unit: Int = 4) -> Double {
        let step = gridStep(bar: bar, beats: beats, pixelsPerSecond: pixelsPerSecond, divisions: divisions, unit: unit)
        guard step > 0 else { return max(0, time) }
        return max(0, (time / step).rounded() * step)
    }
    public static func snap<Anchors: Sequence>(_ time: Double, bar: Double, beats: Int,
                                               pixelsPerSecond: Double, anchors: Anchors,
                                               additionalAnchors: Anchors? = nil,
                                               cursor: Double? = nil, divisions: Int? = nil, unit: Int = 4, enabled: Bool = true) -> Double where Anchors.Element == Double {
        guard time.isFinite, pixelsPerSecond.isFinite, pixelsPerSecond > 0 else { return 0 }
        let position = max(0, time)
        guard enabled else { return position }
        let step = gridStep(bar: bar, beats: beats, pixelsPerSecond: pixelsPerSecond, divisions: divisions, unit: unit)
        var nearest: Double? = step > 0 ? snap(position, bar: bar, beats: beats,
            pixelsPerSecond: pixelsPerSecond, divisions: divisions, unit: unit) : nil
        var distance = nearest.map { abs($0 - position) } ?? .infinity
        func consider(_ anchor: Double) {
            guard anchor.isFinite, anchor >= 0 else { return }
            let delta = abs(anchor - position)
            if delta < distance || (delta == distance && anchor < (nearest ?? .infinity)) {
                nearest = anchor; distance = delta
            }
        }
        for anchor in anchors { consider(anchor) }
        if let additionalAnchors { for anchor in additionalAnchors { consider(anchor) } }
        if let cursor { consider(cursor) }
        return nearest ?? position
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
        return min(TimelineTempo.bpmRange.upperBound, max(TimelineTempo.bpmRange.lowerBound, bpm.rounded()))
    }
}

public extension AudioClip {
    func supportsRate(on track: Track) -> Bool {
        !isImage && (midi != nil || (audioFile ?? track.audioFile) != nil || track.kind == .timecode || track.kind == .click)
    }
    /// Global BPM edits also update playbackRate. Generated clicks already use
    /// the new BPM, so their independent item multiplier stays at its base.
    var clickRate: Double { tempoBasePlaybackRate ?? audioRate }
}

public extension Song {
    /// Reveal the complete source at the current position and playback speed.
    /// Integrating the tempo program avoids a silent tail after a BPM change.
    func restoringItemDuration(_ clip: AudioClip, sourceDuration: Double) -> AudioClip {
        guard sourceDuration.isFinite, sourceDuration > 0 else { return clip }
        var restored = clip
        restored.sourceOffset = 0; restored.loopStart = nil; restored.loopLength = nil
        restored.automationSourceOffset = nil
        restored.fadeTimelineStart = nil; restored.fadeTimelineDuration = nil
        restored.duration = duration(forSourceSpan: sourceDuration, item: restored)
        restored.fadeIn = restored.fadeIn.map { min($0, restored.duration) }
        restored.fadeOut = restored.fadeOut.map { min($0, restored.duration) }
        return restored
    }
    func item(_ clip: AudioClip, withRate rate: Double, on track: Track? = nil) -> AudioClip {
        guard rate.isFinite, (1.0 / 32...32).contains(rate) else { return clip }
        let generatedClick = track?.kind == .click && clip.audioFile == nil
        if rate == (generatedClick ? clip.clickRate : clip.audioRate) { return clip }
        if generatedClick {
            // Preserve the number of source beats through every tempo section,
            // including Free Grid sections: a generated click always uses BPM.
            let end = clip.startTime + clip.duration
            let timing = tempoSections(until: max(duration, end, (markers ?? []).map(\.position).max() ?? 0) + 1)
            let beats = timing.reduce(0.0) { total, section in
                total + max(0, min(end, section.end) - max(clip.startTime, section.start)) * section.bpm / 60 * clip.clickRate
            }
            var remaining = beats, finish = clip.startTime
            for section in timing where section.end > finish {
                let first = max(finish, section.start), speed = section.bpm / 60 * rate
                let available = (section.end - first) * speed
                if remaining <= available { finish = first + remaining / speed; remaining = 0; break }
                remaining -= available; finish = section.end
            }
            if remaining > 0 { finish += remaining / ((timing.last?.bpm ?? bpm) / 60 * rate) }
            var result = clip; result.playbackRate = rate; result.tempoBasePlaybackRate = nil
            result.duration = finish - clip.startTime
            return result
        }
        let sourceSpan = clip.isProjectionMedia ? clip.duration * clip.audioRate : tempoAudioSegments(clip).reduce(0.0) { $0 + $1.duration * $1.audioRate }
        var result = clip; result.playbackRate = rate; result.tempoBasePlaybackRate = nil
        result.duration = duration(forSourceSpan: sourceSpan, item: result)
        result.fadeIn = result.fadeIn.map { min($0, result.duration) }
        result.fadeOut = result.fadeOut.map { min($0, result.duration) }
        return result
    }
    private func duration(forSourceSpan sourceDuration: Double, item clip: AudioClip) -> Double {
        if clip.isProjectionMedia { return sourceDuration / clip.audioRate }
        var probe = clip
        let lastMarker = (markers ?? []).map(\.position).max() ?? 0
        probe.duration = max(duration, lastMarker, clip.startTime) - clip.startTime + sourceDuration / clip.audioRate
        var remaining = sourceDuration, end = clip.startTime
        let segments = tempoAudioSegments(probe)
        for segment in segments {
            let available = segment.duration * segment.audioRate
            if remaining <= available {
                end = segment.startTime + remaining / segment.audioRate; remaining = 0; break
            }
            remaining -= available; end = segment.startTime + segment.duration
        }
        if remaining > 0 { end += remaining / (segments.last?.audioRate ?? clip.audioRate) }
        return end - clip.startTime
    }
    /// An outgoing region can overlap the next song. Its audio tail retains
    /// ownership, but changing its BPM must stop at the next song's onset.
    func tempoEditEnd(for region: Part) -> Double {
        if parts.contains(where: { $0.parentRegionID == region.id }) { return region.endTime }
        return min(region.endTime, tempoOwnerLimit(region))
    }
    func regionTempoChange(_ requestedDelta: Double, region: Part, referenceBPM: Double? = nil) -> [TimelineMarker] {
        let end = tempoEditEnd(for: region)
        var targets = (markers ?? []).filter { $0.isTempo && $0.position >= region.startTime && $0.position < end }
        func boundary(_ position: Double) -> TimelineMarker {
            let section = tempoSection(at: position), active = activeTempoMarker(at: position)
            return TimelineMarker(id: UUID(), name: "TEMPO", position: position, color: 0x999999,
                tempoBPM: section.bpm, tempoBeats: section.beats, tempoUnit: section.unit,
                tempoTimebase: active?.tempoTimebase ?? .global, tempoReferenceBPM: active?.tempoReferenceBPM,
                tempoPlaybackRate: active.map { tempoPlaybackRate(for: $0) } ?? 1)
        }
        if !targets.contains(where: { abs($0.position - region.startTime) < 0.000001 }) { targets.append(boundary(region.startTime)) }
        let bpms = targets.compactMap(\.tempoBPM)
        let reference = referenceBPM ?? tempoSection(at: region.startTime).bpm
        let factor = min(300 / (bpms.max() ?? 120), max(60 / (bpms.min() ?? 120), (reference + requestedDelta) / reference))
        guard abs(factor - 1) > 0.000000001 else { return [] }
        for i in targets.indices {
            let previous = targets[i]
            targets[i].tempoBPM! *= factor
            targets[i] = retainingTempoRate(targets[i], previous: previous)
            targets[i].tempoBeats = targets[i].tempoBeats ?? meterBeats
            targets[i].tempoUnit = targets[i].tempoUnit ?? meterUnit
        }
        if !(markers ?? []).contains(where: { $0.isTempo && abs($0.position - end) < 0.000001 }) { targets.append(boundary(end)) }
        return targets.map { markerWithRegionOwnership($0) }
    }
    /// Highlight actual source-speed processing, not a historical BPM/reference.
    /// Re-render resets the source rate to unity; partial renders cannot clear
    /// the indicator while another owned item still runs at a different rate.
    func hasUnrenderedTempo(in region: Part? = nil) -> Bool {
        let sections = tempoSections(until: duration)
        return tracks.contains { track in
            track.clips.contains { clip in
                guard clip.audioFile != nil || clip.midi != nil || track.audioFile != nil else { return false }
                if let region {
                    let owner = tempoOwner(for: clip)
                    if let owner {
                        guard owner.id == region.id || owner.parentRegionID == region.id else { return false }
                    } else if clip.startTime >= region.endTime || clip.startTime + clip.duration <= region.startTime { return false }
                }
                return tempoAudioSegments(clip, sections: sections).contains { abs($0.audioRate - 1) > 0.0000005 }
            }
        }
    }
    mutating func followTempo(_ value: Double) {
        guard projectTime.timebase == .relative else { bpm = value; return }
        guard value != bpm else { return }
        let speed = value / bpm, scale = 1 / speed
        duration *= scale
        for track in tracks.indices {
            tracks[track].automation?.mapTimelineTimes { $0 * scale }
            if tracks[track].programChanges != nil {
                for marker in tracks[track].programChanges!.indices { tracks[track].programChanges![marker].position *= scale }
            }
            for clip in tracks[track].clips.indices {
                let end = (tracks[track].clips[clip].startTime + tracks[track].clips[clip].duration) * scale
                tracks[track].clips[clip].startTime *= scale
                tracks[track].clips[clip].duration = end - tracks[track].clips[clip].startTime
                if tracks[track].clips[clip].tempoBasePlaybackRate == nil {
                    tracks[track].clips[clip].tempoBasePlaybackRate = tracks[track].clips[clip].audioRate
                }
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
    mutating func configureTiming(bpm value: Double, beats: Int, unit: Int, settings: ProjectTimeSettings) {
        retainTempoPlaybackRates()
        timeSettings = settings
        if settings.timebase == .relative {
            followTempo(value)
        }
        bpm = value; beatsPerBar = beats; beatUnit = unit
    }
}

/// Tempo changes stay anchored in seconds. The grid follows every section;
/// playback uses each marker's timebase, inheriting the project in Global mode.
public struct TimelineTempoSection: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let bpm: Double
    public let beats: Int
    public let unit: Int
    public let timebase: ProjectTimebase
    public var referenceBPM: Double? = nil
    public var regionOwnerID: UUID? = nil
    public var playbackRate: Double? = nil
    public var markerID: UUID? = nil
    public func audioRate(baseBPM: Double) -> Double { playbackRate ?? (timebase == .relative ? bpm / (referenceBPM ?? baseBPM) : 1) }
    public var barSeconds: Double { 60 / bpm * Double(beats) * 4 / Double(unit) }
}
public extension Song {
    func canDragMarker(_ marker: TimelineMarker) -> Bool {
        guard marker.sourceRegionID == nil, marker.unifiedRegionID == nil else { return false }
        return !marker.isTempo || !parts.contains { marker.position >= $0.startTime && marker.position < $0.endTime }
    }
    func markerDragPosition(_ marker: TimelineMarker, to value: Double, pixelsPerSecond: Double, free: Bool, cursor: Double? = nil) -> Double {
        guard canDragMarker(marker), value.isFinite else { return marker.position }
        var target = max(0, value)
        if !marker.isTempo { return free ? target : TimelineTempo.snap(target, song: self, pixelsPerSecond: pixelsPerSecond, cursor: cursor, excludingMarker: marker.id) }
        if !free, let cursor, cursor.isFinite, cursor >= 0, pixelsPerSecond.isFinite, pixelsPerSecond > 0,
           abs(cursor - target) * pixelsPerSecond <= 12 + 1e-9 { target = cursor }
        var intervals: [(Double, Double)] = []
        for part in parts.sorted(by: { $0.startTime < $1.startTime }) {
            if let last = intervals.last, part.startTime <= last.1 {
                intervals[intervals.count - 1].1 = max(last.1, part.endTime)
            } else { intervals.append((part.startTime, part.endTime)) }
        }
        if let blocked = intervals.first(where: { target >= $0.0 && target < $0.1 }) {
            return marker.position < blocked.0 ? max(0, blocked.0 - 0.000001) : blocked.1
        }
        return target
    }
    func activeTempoMarker(at position: Double) -> TimelineMarker? {
        (markers ?? []).lazy.filter { $0.isTempo && $0.position <= position }.max {
            $0.position == $1.position ? $0.id.uuidString < $1.id.uuidString : $0.position < $1.position
        }
    }
    func tempoPlaybackRate(for marker: TimelineMarker) -> Double {
        marker.tempoPlaybackRate ?? ((marker.tempoTimebase ?? .global).resolved(project: projectTime.timebase) == .relative ? (marker.tempoBPM ?? bpm) / (marker.tempoReferenceBPM ?? bpm) : 1)
    }
    func retainingTempoRate(_ marker: TimelineMarker, previous: TimelineMarker?) -> TimelineMarker {
        var result = marker
        guard let newBPM = marker.tempoBPM else { result.tempoPlaybackRate = nil; return result }
        if let previous, let oldBPM = previous.tempoBPM {
            let factor = (marker.tempoTimebase ?? .global).resolved(project: projectTime.timebase) == .relative ? newBPM / oldBPM : 1
            result.tempoPlaybackRate = tempoPlaybackRate(for: previous) * factor
        } else if result.tempoPlaybackRate == nil {
            let active = activeTempoMarker(at: marker.position)
            let oldBPM = active?.tempoBPM ?? bpm
            let factor = (marker.tempoTimebase ?? .global).resolved(project: projectTime.timebase) == .relative ? newBPM / oldBPM : 1
            result.tempoPlaybackRate = (active.map { tempoPlaybackRate(for: $0) } ?? 1) * factor
        }
        return result
    }
    mutating func retainTempoPlaybackRates() {
        guard let original = markers else { return }
        for i in original.indices where original[i].isTempo { markers![i].tempoPlaybackRate = tempoPlaybackRate(for: original[i]) }
    }
    var tempoMarkersAffectAudio: Bool {
        (markers ?? []).contains { $0.isTempo && (($0.tempoTimebase ?? .global).resolved(project: projectTime.timebase) == .relative || $0.tempoPlaybackRate != nil) }
    }
    func tempoSections(until end: Double) -> [TimelineTempoSection] {
        var result: [TimelineTempoSection] = []
        var start = 0.0, tempo = bpm, beats = meterBeats, unit = meterUnit
        var timebase = projectTime.timebase
        var referenceBPM: Double? = nil
        var playbackRate: Double? = nil
        var markerID: UUID? = nil
        var regionOwnerID: UUID? = nil
        for marker in (markers ?? []).filter(\.isTempo).sorted(by: { $0.position == $1.position ? $0.id.uuidString < $1.id.uuidString : $0.position < $1.position }) {
            guard marker.position <= end else { break }
            if marker.position > start { result.append(TimelineTempoSection(start: start, end: marker.position, bpm: tempo, beats: beats, unit: unit, timebase: timebase, referenceBPM: referenceBPM, regionOwnerID: regionOwnerID, playbackRate: playbackRate, markerID: markerID)) }
            start = marker.position; tempo = marker.tempoBPM!; beats = marker.tempoBeats ?? 4; unit = marker.tempoUnit ?? 4
            timebase = (marker.tempoTimebase ?? .global).resolved(project: projectTime.timebase)
            referenceBPM = marker.tempoReferenceBPM
            playbackRate = marker.tempoPlaybackRate
            markerID = marker.id
            regionOwnerID = marker.regionOwnerID
        }
        if end > start { result.append(TimelineTempoSection(start: start, end: end, bpm: tempo, beats: beats, unit: unit, timebase: timebase, referenceBPM: referenceBPM, regionOwnerID: regionOwnerID, playbackRate: playbackRate, markerID: markerID)) }
        return result
    }
    func tempoSection(at position: Double) -> TimelineTempoSection {
        guard position.isFinite, position >= 0 else {
            return tempoSections(until: max(duration, position + 1)).last { $0.start <= position }
                ?? TimelineTempoSection(start: 0, end: duration, bpm: bpm, beats: meterBeats, unit: meterUnit, timebase: projectTime.timebase)
        }
        // Playback needs one section, not a sorted array of every tempo in the
        // project. Find its two boundaries without allocating or sorting on
        // every transport sample. Keep the same UUID order for equal markers.
        var active: TimelineMarker?
        var end = max(duration, position + 1)
        for marker in markers ?? [] where marker.isTempo {
            if marker.position > position {
                end = min(end, marker.position)
            } else if active == nil || marker.position > active!.position ||
                        (marker.position == active!.position && marker.id.uuidString > active!.id.uuidString) {
                active = marker
            }
        }
        guard let active else {
            return TimelineTempoSection(start: 0, end: end, bpm: bpm, beats: meterBeats, unit: meterUnit, timebase: projectTime.timebase)
        }
        return TimelineTempoSection(start: active.position, end: end, bpm: active.tempoBPM!,
            beats: active.tempoBeats ?? 4, unit: active.tempoUnit ?? 4,
            timebase: (active.tempoTimebase ?? .global).resolved(project: projectTime.timebase), referenceBPM: active.tempoReferenceBPM, regionOwnerID: active.regionOwnerID, playbackRate: active.tempoPlaybackRate, markerID: active.id)
    }
    /// Persisted attachment wins over overlap or a trimmed start inside the next
    /// song. A unified-container attachment resolves only among its own songs.
    func tempoOwner(for clip: AudioClip) -> Part? {
        if let id = clip.regionOwnerID {
            guard let owner = parts.first(where: { $0.id == id }) else { return nil }
            return parts.filter { $0.parentRegionID == id && $0.startTime <= clip.startTime }.max {
                $0.startTime == $1.startTime ? $0.id.uuidString < $1.id.uuidString : $0.startTime < $1.startTime
            } ?? owner
        }
        return regionOwnershipInitialized == true ? nil : tempoOwner(at: clip.startTime)
    }
    /// Ownership follows the item's start, never its tail across the next song.
    func tempoOwner(at position: Double) -> Part? {
        let folders = Set(parts.compactMap(\.parentRegionID))
        return parts.filter {
            guard !folders.contains($0.id), $0.startTime <= position else { return false }
            if let parent = $0.parentRegionID, let group = parts.first(where: { $0.id == parent }) {
                return position < group.endTime
            }
            return position < $0.endTime
        }.max {
            $0.startTime == $1.startTime ? $0.id.uuidString < $1.id.uuidString : $0.startTime < $1.startTime
        }
    }
    func tempoOwnerLimit(_ owner: Part) -> Double {
        let folders = Set(parts.compactMap(\.parentRegionID))
        let end = owner.parentRegionID.flatMap { id in parts.first { $0.id == id }?.endTime } ?? owner.endTime
        return min(end, parts.filter {
            !folders.contains($0.id) && $0.startTime > owner.startTime &&
                (owner.parentRegionID == nil || $0.parentRegionID == owner.parentRegionID)
        }.map(\.startTime).min() ?? end)
    }
    func audioTempoSections(owner: Part?, until end: Double, sections: [TimelineTempoSection]? = nil) -> [TimelineTempoSection] {
        let all = sections ?? tempoSections(until: end)
        guard let owner else { return all }
        let limit = tempoOwnerLimit(owner)
        let owned = all.filter {
            $0.start >= owner.startTime && $0.start < limit &&
                ($0.regionOwnerID == nil || $0.regionOwnerID == owner.id || $0.regionOwnerID == owner.parentRegionID)
        }
        var result: [TimelineTempoSection] = []
        var start = 0.0
        var current = TimelineTempoSection(start: 0, end: end, bpm: bpm, beats: meterBeats, unit: meterUnit, timebase: .free)
        for section in owned where section.start < end {
            if section.start > start {
                result.append(TimelineTempoSection(start: start, end: section.start, bpm: current.bpm, beats: current.beats, unit: current.unit, timebase: current.timebase, referenceBPM: current.referenceBPM, playbackRate: current.playbackRate, markerID: current.markerID))
            }
            start = section.start; current = section
        }
        if start < end { result.append(TimelineTempoSection(start: start, end: end, bpm: current.bpm, beats: current.beats, unit: current.unit, timebase: current.timebase, referenceBPM: current.referenceBPM, playbackRate: current.playbackRate, markerID: current.markerID)) }
        return result
    }
    /// Timecode advances in the same source clock as audio and MIDI, while its
    /// configured FPS and absolute offset retain their protocol meanings.
    func timecodePlaybackSegments(_ clip: AudioClip, origin: Double) -> [AudioClip] {
        var item = clip
        if origin != clip.startTime {
            var prefix = clip; prefix.startTime = min(origin, clip.startTime)
            prefix.duration = abs(clip.startTime - origin); prefix.sourceOffset = 0
            let elapsed = tempoAudioSegments(prefix).reduce(0.0) { $0 + $1.duration * $1.audioRate }
            item.sourceOffset += clip.startTime >= origin ? elapsed : -elapsed
        }
        return tempoAudioSegments(item)
    }
    /// Temporary playback fragments preserve item edits and source continuity.
    /// They do not split project items or create additional media files.
    func tempoAudioSegments(_ clip: AudioClip, sections: [TimelineTempoSection]? = nil) -> [AudioClip] {
        // Printed performances already contain their tempo changes.
        guard clip.frozenMIDI != true, clip.renderedTiming != true, clip.renderedTempo != true else { return [clip] }
        guard tempoMarkersAffectAudio else { return [clip] }
        return tempoAudioSegments(clip, program: audioTempoSections(owner: tempoOwner(for: clip), until: clip.startTime + clip.duration, sections: sections))
    }
    func resettingItemRate(_ clip: AudioClip) -> AudioClip {
        var result = clip; result.playbackRate = 1; result.tempoBasePlaybackRate = nil
        let references = (markers ?? []).filter(\.isTempo).map { ItemTempoReference(markerID: $0.id, rate: tempoPlaybackRate(for: $0)) }
        result.tempoRateReferences = references.isEmpty ? nil : references
        return result
    }
    func itemTempoReference(_ clip: AudioClip, at time: Double, program: [TimelineTempoSection]) -> Double {
        guard let references = clip.tempoRateReferences, !references.isEmpty else { return 1 }
        var result = 1.0
        for section in program {
            if section.start > time { break }
            if let id = section.markerID, let reference = references.first(where: { $0.markerID == id }) { result = reference.rate }
        }
        return result
    }
    func tempoAudioSegments(_ clip: AudioClip, program: [TimelineTempoSection]) -> [AudioClip] {
        let end = clip.startTime + clip.duration
        var source = clip.sourceOffset, result: [AudioClip] = []
        for section in program where section.end > clip.startTime && section.start < end {
            let start = max(clip.startTime, section.start), finish = min(end, section.end)
            guard finish > start else { continue }
            var segment = clip
            if !result.isEmpty {
                var bytes = clip.id.uuid
                withUnsafeMutableBytes(of: &bytes) { values in
                    let bits = start.bitPattern
                    for i in 0..<8 { values[i + 8] ^= UInt8(truncatingIfNeeded: bits >> (i * 8)) }
                    values[6] = (values[6] & 0x0f) | 0x40; values[8] = (values[8] & 0x3f) | 0x80
                }
                segment.id = UUID(uuid: bytes)
            }
            segment.fadeTimelineStart = clip.startTime; segment.fadeTimelineDuration = clip.duration
            segment.startTime = start; segment.duration = finish - start
            segment.playbackRate = clip.audioRate * section.audioRate(baseBPM: bpm) / itemTempoReference(clip, at: section.start, program: program)
            segment.sourceOffset = source
            segment.automationSourceOffset = clip.automation == nil ? nil : source
            if let length = clip.loopLength, length > 0 {
                let origin = clip.loopStart ?? 0
                segment.sourceOffset = origin + ((source - origin).truncatingRemainder(dividingBy: length) + length).truncatingRemainder(dividingBy: length)
            }
            if let previous = result.last, abs(previous.audioRate - segment.audioRate) < 0.000000001 {
                result[result.count - 1].duration += segment.duration
            } else { result.append(segment) }
            source += segment.duration * segment.audioRate
        }
        return result
    }
}

public extension TimelineTempo {
    static func snap(_ time: Double, song: Song, pixelsPerSecond: Double, regionEnds: Bool = true,
                     cursor: Double? = nil, enabled: Bool = true,
                     otherCursors: [Double] = [], excludingRegion: UUID? = nil, excludingMarker: UUID? = nil,
                     includeItemEdges: Bool = false, excludingItems: Set<UUID> = [],
                     maximumDistancePixels: Double? = nil) -> Double {
        guard time.isFinite, pixelsPerSecond.isFinite, pixelsPerSecond > 0 else { return 0 }
        let position = max(0, time)
        guard enabled else { return position }
        // Item drags use a finite screen-space magnet. Ordinary cursor placement
        // can still request unconditional musical division quantization.
        let maximumDistance = maximumDistancePixels.map { $0.isFinite ? max(0, $0) : 0 }
        let strongRadius = min(12, maximumDistance ?? 12)
        // Cursor and media edges win over musical divisions inside this radius.
        var strong: Double?
        func considerStrong(_ anchor: Double) {
            guard anchor.isFinite, anchor >= 0, abs(anchor - position) * pixelsPerSecond <= strongRadius + 1e-9 else { return }
            if strong == nil || abs(anchor - position) < abs(strong! - position) || (abs(anchor - position) == abs(strong! - position) && anchor < strong!) { strong = anchor }
        }
        if let cursor { considerStrong(cursor) }
        for cursor in otherCursors { considerStrong(cursor) }
        if includeItemEdges {
            for track in song.tracks { for item in track.clips where !excludingItems.contains(item.id) { considerStrong(item.startTime); considerStrong(item.startTime + item.duration) } }
        }
        if let strong { return strong }
        let section = song.tempoSection(at: position)
        // Use the same musical spacing as the visible ruler and grid.
        let divisions = song.projectTime.divisions
        let step = gridStep(bar: section.barSeconds, beats: section.beats, pixelsPerSecond: pixelsPerSecond,
                            divisions: divisions, unit: section.unit)
        var nearest: Double = 0
        var distance = position
        func consider(_ anchor: Double) {
            guard anchor.isFinite, anchor >= 0 else { return }
            let delta = abs(anchor - position)
            if delta < distance || (delta == distance && anchor < nearest) {
                nearest = anchor; distance = delta
            }
        }
        // Work in absolute time: anchors before the active tempo section must
        // remain candidates too. Shift bypasses every anchor above.
        if step > 0 {
            let origin = step < section.barSeconds
                ? section.start + floor((position - section.start) / section.barSeconds) * section.barSeconds : section.start
            let limit = min(section.end, step < section.barSeconds ? origin + section.barSeconds : section.end)
            let offset = (position - origin) / step
            consider(min(limit, origin + floor(offset) * step))
            consider(min(limit, origin + ceil(offset) * step))
        }
        for part in song.parts where excludingRegion == nil || (part.id != excludingRegion && part.parentRegionID != excludingRegion) {
            consider(part.startTime)
            if regionEnds { consider(part.endTime) }
        }
        for marker in song.markers ?? [] where marker.id != excludingMarker { consider(marker.position) }
        if includeItemEdges {
            for track in song.tracks { for item in track.clips where !excludingItems.contains(item.id) {
                consider(item.startTime)
                consider(item.startTime + item.duration)
            } }
        }
        if let cursor { consider(cursor) }
        for cursor in otherCursors { consider(cursor) }
        // A visible musical grid always quantizes the drop. With divisions
        // disabled, retain the capture radius for cursor and media edges.
        if step <= 0, let maximumDistance, distance * pixelsPerSecond > maximumDistance + 1e-9 { return position }
        return nearest
    }
}

extension Song {
    /// An explicit initial section keeps the empty lead-in visible in the tempo lane.
    var initialTempoMarkerIfNeeded: TimelineMarker? {
        guard let first = markers?.filter(\.isTempo).map(\.position).min(), first > 0 else { return nil }
        return TimelineMarker(id: UUID(), name: "TEMPO", position: 0, color: 0x999999,
            regionOwnerID: regionOwner(at: 0), tempoBPM: 120, tempoBeats: 4, tempoUnit: 4, tempoTimebase: .global, tempoReferenceBPM: 120)
    }
    mutating func ensureInitialTempoMarker() {
        if let initial = initialTempoMarkerIfNeeded { markers!.insert(initial, at: 0) }
    }
}

/// One immutable song revision, with owned tempo programs reused by all stems.
/// The renderer guards this value with its own lock; playback owns a local copy.
struct AudioTempoPrograms {
    private let song: Song
    private let affectsAudio: Bool
    private let parts: [UUID: Part]
    private let children: [UUID: [Part]]
    private let sections: [TimelineTempoSection]
    private struct Key: Hashable { let owner: UUID; let end: Double }
    private var owned: [Key: [TimelineTempoSection]] = [:]
    init(song: Song) {
        self.song = song; affectsAudio = song.tempoMarkersAffectAudio
        parts = Dictionary(uniqueKeysWithValues: song.parts.map { ($0.id, $0) })
        children = Dictionary(grouping: song.parts.filter { $0.parentRegionID != nil }, by: { $0.parentRegionID! })
        sections = song.tempoSections(until: song.duration)
    }
    private func owner(for clip: AudioClip) -> Part? {
        guard let id = clip.regionOwnerID else { return song.regionOwnershipInitialized == true ? nil : song.tempoOwner(at: clip.startTime) }
        guard let part = parts[id] else { return nil }
        return children[id]?.filter { $0.startTime <= clip.startTime }.max {
            $0.startTime == $1.startTime ? $0.id.uuidString < $1.id.uuidString : $0.startTime < $1.startTime
        } ?? part
    }
    mutating func program(for clip: AudioClip) -> [TimelineTempoSection] {
        guard let owner = owner(for: clip) else { return sections }
        let key = Key(owner: owner.id, end: max(song.duration, clip.startTime + clip.duration))
        if let cached = owned[key] { return cached }
        let value = song.audioTempoSections(owner: owner, until: key.end, sections: sections)
        owned[key] = value
        return value
    }
    mutating func fragments(for clip: AudioClip) -> [AudioClip] {
        guard affectsAudio, clip.frozenMIDI != true, clip.renderedTiming != true, clip.renderedTempo != true else { return [clip] }
        return song.tempoAudioSegments(clip, program: program(for: clip))
    }
}

private struct TempoRateLookup {
    private var points: [(time: Double, rate: Double)] = []
    init(song: Song) {
        for marker in (song.markers ?? []).filter(\.isTempo).sorted(by: { $0.position == $1.position ? $0.id.uuidString < $1.id.uuidString : $0.position < $1.position }) {
            let rate = song.tempoPlaybackRate(for: marker)
            points.append((marker.position, rate))
        }
    }
    func rate(at time: Double) -> Double {
        var low = 0, high = points.count
        while low < high { let mid = (low + high) / 2; if points[mid].time <= time { low = mid + 1 } else { high = mid } }
        return low == 0 ? 1 : points[low - 1].rate
    }
}

/// Maps a tempo edit without consuming or discarding source audio. Empty gaps
/// remain seconds; occupied song/clip intervals retain their musical duration.
struct TempoEditMap {
    private struct Span { let start: Double; let end: Double; let output: Double; let scale: Double }
    private var spans: [Span] = []
    private var clipDurations: [UUID: Double] = [:]
    private var clipStarts: [UUID: Double] = [:]
    private var regionDurations: [UUID: Double] = [:]
    private var tempoEndRegions: [UUID: UUID] = [:]
    private var markerStarts: [UUID: Double] = [:]
    var changesTime: Bool { spans.contains { abs($0.scale - 1) > 1e-12 } }
    init(before: Song, after: Song) {
        let folderIDs = Set(before.parts.compactMap(\.parentRegionID))
        // Owned overlapping tails can give a unified region a different end
        // from the global time map. Keep its restoring tempo at that actual
        // end, otherwise the next edit treats it as an internal tempo change.
        let groups = before.parts.filter { folderIDs.contains($0.id) }
        for marker in after.markers ?? [] where marker.isTempo && marker.regionOwnerID == nil {
            guard !before.parts.contains(where: { abs($0.startTime - marker.position) < 0.000001 }),
                  let group = groups.first(where: { abs($0.endTime - marker.position) < 0.000001 }) else { continue }
            tempoEndRegions[marker.id] = group.id
        }
        var occupied = before.parts.filter { !folderIDs.contains($0.id) }.map { ($0.startTime, $0.endTime) }
        occupied += before.tracks.flatMap { track in
            track.clips.filter { $0.supportsRate(on: track) && before.tempoOwner(for: $0) == nil }.map { ($0.startTime, $0.startTime + $0.duration) }
        }
        occupied.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        var merged: [(Double, Double)] = []
        for interval in occupied where interval.1 > interval.0 {
            if let last = merged.last, last.1 >= interval.0 { merged[merged.count - 1].1 = max(last.1, interval.1) }
            else { merged.append(interval) }
        }
        occupied = merged
        var points = [0.0, before.duration, after.duration]
        points += occupied.flatMap { [$0.0, $0.1] }
        points += (before.markers ?? []).filter(\.isTempo).map(\.position)
        points += (after.markers ?? []).filter(\.isTempo).map(\.position)
        points = Array(Set(points.filter { $0.isFinite && $0 >= 0 })).sorted()
        let oldRates = TempoRateLookup(song: before), newRates = TempoRateLookup(song: after)
        var output = 0.0
        for (start, end) in zip(points, points.dropFirst()) {
            let middle = start + (end - start) / 2
            let filled = occupied.contains { $0.0 <= middle && middle < $0.1 }
            let scale = filled ? oldRates.rate(at: middle) / newRates.rate(at: middle) : 1
            spans.append(Span(start: start, end: end, output: output, scale: scale))
            output += (end - start) * scale
        }
        // Every stem in a region uses the same owned tempo program. Build
        // and sort it once, not twice per item for both its offset and length.
        let timelineEnd = max(before.duration, after.duration,
            before.tracks.flatMap(\.clips).map { $0.startTime + $0.duration }.max() ?? 0,
            before.parts.map(\.endTime).max() ?? 0)
        let oldSections = before.tempoSections(until: timelineEnd)
        let newSections = after.tempoSections(until: timelineEnd)
        let nextOwners = Dictionary(uniqueKeysWithValues: after.parts.map { ($0.id, $0) })
        var ownerSpans: [UUID: [Span]] = [:]
        func resizedDuration(start: Double, end: Double, owner: Part) -> Double {
            if ownerSpans[owner.id] == nil {
                let old = before.audioTempoSections(owner: owner, until: timelineEnd, sections: oldSections)
                let new = after.audioTempoSections(owner: nextOwners[owner.id] ?? owner, until: timelineEnd, sections: newSections)
                let edges = Array(Set([0, timelineEnd] + (old + new).flatMap { [$0.start, $0.end] })).sorted()
                func speed(_ sections: [TimelineTempoSection], _ time: Double, _ song: Song) -> Double {
                    guard let section = sections.last(where: { $0.start <= time }) else { return 1 }
                    return section.audioRate(baseBPM: song.bpm)
                }
                var program: [Span] = [], output = 0.0
                for (first, last) in zip(edges, edges.dropFirst()) {
                    let middle = first + (last - first) / 2
                    let scale = speed(old, middle, before) / speed(new, middle, after)
                    program.append(Span(start: first, end: last, output: output, scale: scale))
                    output += (last - first) * scale
                }
                ownerSpans[owner.id] = program
            }
            let program = ownerSpans[owner.id]!
            return Self.position(end, in: program) - Self.position(start, in: program)
        }
        let folders = Set(before.parts.compactMap(\.parentRegionID))
        for marker in after.markers ?? [] {
            guard let ownerID = marker.regionOwnerID,
                  let owner = before.parts.first(where: { $0.id == ownerID }), !folders.contains(ownerID) else { continue }
            let offset = resizedDuration(start: min(owner.startTime, marker.position), end: max(owner.startTime, marker.position), owner: owner)
            markerStarts[marker.id] = position(owner.startTime) + (marker.position < owner.startTime ? -offset : offset)
        }
        for part in before.parts where !folders.contains(part.id) {
            regionDurations[part.id] = resizedDuration(start: part.startTime, end: part.endTime, owner: part)
        }
        for track in before.tracks {
            for clip in track.clips {
                if let owner = before.tempoOwner(for: clip) {
                    clipDurations[clip.id] = resizedDuration(start: clip.startTime, end: clip.startTime + clip.duration, owner: owner)
                    let offset = resizedDuration(start: min(owner.startTime, clip.startTime), end: max(owner.startTime, clip.startTime), owner: owner)
                    clipStarts[clip.id] = position(owner.startTime) + (clip.startTime < owner.startTime ? -offset : offset)
                }
            }
        }
    }
    func position(_ time: Double) -> Double { Self.position(time, in: spans) }
    private static func position(_ time: Double, in spans: [Span]) -> Double {
        guard time.isFinite, time >= 0, let last = spans.last else { return time }
        var low = 0, high = spans.count
        while low < high { let mid = (low + high) / 2; if spans[mid].end <= time { low = mid + 1 } else { high = mid } }
        guard low < spans.count else { return last.output + (last.end - last.start) * last.scale + time - last.end }
        let span = spans[low]
        return span.output + (time - span.start) * span.scale
    }
    func apply(to song: inout Song) {
        guard changesTime else { return }
        for track in song.tracks.indices {
            song.tracks[track].automation?.mapTimelineTimes { position($0) }
            if song.tracks[track].programChanges != nil {
                for marker in song.tracks[track].programChanges!.indices {
                    song.tracks[track].programChanges![marker].position = position(song.tracks[track].programChanges![marker].position)
                }
            }
            for item in song.tracks[track].clips.indices {
                let clip = song.tracks[track].clips[item]
                let start = clipStarts[clip.id] ?? position(clip.startTime), end = position(clip.startTime + clip.duration)
                let duration = clipDurations[clip.id] ?? (end - start)
                // A printed source already contains the former tempo map. Keep
                // that map bypassed, but follow later tempo edits by preserving
                // the source span while its timeline duration changes.
                if (clip.renderedTempo == true || clip.renderedTiming == true || clip.frozenMIDI == true),
                   duration > 0, clip.duration > 0, abs(duration - clip.duration) > 0.000000001 {
                    song.tracks[track].clips[item].tempoBasePlaybackRate = clip.tempoBasePlaybackRate ?? clip.audioRate
                    song.tracks[track].clips[item].playbackRate = clip.audioRate * clip.duration / duration
                }
                song.tracks[track].clips[item].startTime = start
                song.tracks[track].clips[item].duration = duration
            }
        }
        for i in song.parts.indices {
            song.parts[i].startTime = position(song.parts[i].startTime)
            song.parts[i].endTime = regionDurations[song.parts[i].id].map { song.parts[i].startTime + $0 } ?? position(song.parts[i].endTime)
        }
        for i in song.parts.indices {
            let children = song.parts.filter { $0.parentRegionID == song.parts[i].id }
            if let end = children.map(\.endTime).max() { song.parts[i].endTime = end }
        }
        // Persist mapped edges before the engine regenerates native timecode
        // items from their owning regions and these two offsets.
        for row in song.tracks.indices where song.tracks[row].kind == .timecode && song.tracks[row].importedTimecodeItems != true {
            for index in song.tracks[row].clips.indices {
                let clip = song.tracks[row].clips[index]
                guard clip.audioFile == nil, let part = song.parts.first(where: { Project.timecodeItemID($0.id) == clip.id }) else { continue }
                song.tracks[row].clips[index].timecodeStartOffset = clip.startTime - part.startTime
                song.tracks[row].clips[index].timecodeEndOffset = clip.startTime + clip.duration - part.endTime
            }
        }
        if song.markers != nil {
            let ends = Dictionary(uniqueKeysWithValues: song.parts.map { ($0.id, $0.endTime) })
            for i in song.markers!.indices {
                song.markers![i].position = tempoEndRegions[song.markers![i].id].flatMap { ends[$0] }
                    ?? markerStarts[song.markers![i].id] ?? position(song.markers![i].position)
            }
        }
        song.duration = position(song.duration)
        for track in song.tracks { for clip in track.clips { song.duration = max(song.duration, clip.startTime + clip.duration) } }
        for part in song.parts { song.duration = max(song.duration, part.endTime) }
    }
    func apply(to transport: inout TransportState) {
        guard changesTime else { return }
        transport.position = position(transport.position)
        transport.editPosition = transport.editPosition.map(position)
        transport.subPlay.position = position(transport.subPlay.position)
        transport.queueStartedAt = transport.queueStartedAt.map(position)
        transport.loop.start = transport.loop.start.map(position); transport.loop.end = transport.loop.end.map(position)
        transport.ignoreNextAfter = transport.ignoreNextAfter.map(position); transport.ignoreNextEnd = transport.ignoreNextEnd.map(position)
        if transport.multiLoop != nil {
            transport.multiLoop!.start = position(transport.multiLoop!.start)
            transport.multiLoop!.end = position(transport.multiLoop!.end)
        }
    }
}

/// Advanced preferences belong to the application; tempo-marker overrides remain song data.
public struct GlobalProjectTiming: Codable, Equatable, Sendable {
    public var bpm: Double
    public var beats: Int
    public var unit: Int
    public var settings: ProjectTimeSettings
    public init(bpm: Double = 120, beats: Int = 4, unit: Int = 4, settings: ProjectTimeSettings = ProjectTimeSettings()) {
        self.bpm = bpm; self.beats = beats; self.unit = unit; self.settings = settings
    }
    public init(song: Song) {
        self.init(bpm: song.bpm, beats: song.meterBeats, unit: song.meterUnit, settings: song.projectTime)
    }
    public static func load(preferences: UserDefaults = .standard) -> Self? {
        guard let data = preferences.data(forKey: "jaras.advanced.globalTiming"),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.bpm.isFinite,
              TimelineTempo.bpmRange.contains(value.bpm), (1...32).contains(value.beats), TimelineTempo.beatUnits.contains(value.unit),
              (try? value.settings.validate()) != nil else { return nil }
        return value
    }
    public func save(preferences: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        preferences.set(data, forKey: "jaras.advanced.globalTiming")
    }
    public func applyOnOpen(to project: inout Project) {
        guard project.importedTimeline != true else { return }
        apply(to: &project)
    }
    public func apply(to project: inout Project) {
        for i in project.songs.indices { project.songs[i].configureTiming(bpm: bpm, beats: beats, unit: unit, settings: settings) }
    }
}

/// One set of musical positions for both the grid and its elapsed-time ruler.
public enum TimelineTimeRuler {
    public static let labelGap = 14.0
    /// Monospaced ruler text can include milliseconds and more than two hour
    /// digits. Use the whole timeline's width so scrolling never changes labels.
    public static func labelSample(through end: Double) -> String {
        // Include a possible carry when a fractional second rounds to the next hour.
        let hours = end.isFinite ? Int(max(0, min((end + 0.001) / 3600, Double(Int.max / 3600)))) : 0
        let hourText = String(hours)
        return (hourText.count < 2 ? "0" + hourText : hourText) + ":59:59.999"
    }
    public static func labelSpacing(through end: Double, measuredWidth: Double? = nil,
                                    pixelsPerSecond scale: Double? = nil) -> Double {
        // The shared renderer uses a 9-point monospaced font. Six points per
        // character plus image padding is conservative when no font is available.
        let estimate = Double(labelSample(through: end).count) * 6 + 2
        let width = measuredWidth.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? estimate
        // More distant views should show a few useful time references, even
        // when many short regions each introduce a new tempo section. Keep
        // the same musical ticks and thin only their elapsed-time labels.
        let distance = scale.flatMap { $0.isFinite && $0 > 0 ? min(1, max(0, -log10($0))) : nil } ?? 0
        return max(130 + 50 * distance, ceil(width) + labelGap)
    }
    public struct Tick {
        public let time: Double
        public let primary: Bool
        /// Empty when the next label would be too close. The tick is still drawn.
        public let label: String
    }
    public static func ticks(in sections: [TimelineTempoSection], from start: Double, to end: Double,
                             pixelsPerSecond scale: Double, divisions: Int = 4, labels: Bool = true,
                             minimumLabelSpacing: Double? = nil) -> [Tick] {
        guard start.isFinite, end.isFinite, scale.isFinite, scale > 0, end >= start else { return [] }
        let spacing = minimumLabelSpacing.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? labelSpacing(through: sections.last?.end ?? end, pixelsPerSecond: scale)
        let labelSeconds = spacing / scale
        let columnSeconds = TimelineTempo.minimumGridSpacing / 2 / scale
        let densityStart = floor(max(0, start) / columnSeconds) * columnSeconds
        // Finish the last column before clipping, so tiled/scrolling views
        // choose the same representative even at the viewport's right edge.
        let densityEnd = (floor(end / columnSeconds) + 1) * columnSeconds
        var result: [Tick] = []
        var lastColumn: Double?
        var lastColumnHasLabel = false
        func firstSection(endingAfter time: Double) -> Int {
            var low = 0, high = sections.count
            while low < high {
                let middle = (low + high) / 2
                if sections[middle].end <= time { low = middle + 1 } else { high = middle }
            }
            return low
        }
        // Every reference has fixed higher-priority neighbours. Its visibility
        // depends only on their distance and zoom, never on which other labels
        // happened to be drawn first. This preserves references across tempo
        // boundaries as well as within a bar (8 -> 4 -> 2 -> 1 subdivisions).
        func hierarchyStep(_ index: Int) -> Int { index & (~index + 1) }
        var sectionIndex = firstSection(endingAfter: densityStart)
        while sectionIndex < sections.count {
            let indexOfSection = sectionIndex
            let section = sections[sectionIndex]
            if section.start > densityEnd { break }
            sectionIndex += 1
            let bar = section.barSeconds
            guard bar.isFinite, bar > 0, section.start.isFinite, section.end.isFinite,
                  section.end > section.start else { continue }
            let boundaryEnd = sectionIndex < sections.count ? section.end : Double.infinity
            let strideBars = TimelineTempo.barStride(bar: bar, pixelsPerSecond: scale)
            let first = max(0, Int(floor((densityStart - section.start) / bar)) / strideBars * strideBars)
            let last = max(first, Int(ceil((min(section.end, densityEnd) - section.start) / bar)))
            let beat = bar / Double(section.beats)
            // Reveal groups of beats as space opens between bar lines.
            // Finer configured divisions follow at closer zoom.
            let base = min(beat, beat * Double(section.unit) / Double(divisions == 0 ? 4 : divisions))
            let minor = TimelineTempo.gridStep(bar: bar, beats: section.beats, pixelsPerSecond: scale,
                                               divisions: divisions == 0 ? 4 : divisions, unit: section.unit)
            guard base > 0, base.isFinite, minor > 0, minor.isFinite else { continue }
            let boundaryClearance: Double
            if indexOfSection == 0 { boundaryClearance = .infinity }
            else {
                let step = hierarchyStep(indexOfSection)
                let left = sections[indexOfSection - step].start
                let right = indexOfSection + step < sections.count ? sections[indexOfSection + step].start : Double.infinity
                boundaryClearance = min(section.start - left, right - section.start)
            }
            func append(_ time: Double, primary: Bool, clearance: Double) {
                guard time >= densityStart, time <= densityEnd, time < section.end else { return }
                let labeled = clearance + 1e-9 >= labelSeconds
                let column = floor(time / columnSeconds + 1e-9)
                if column == lastColumn {
                    guard labeled && !lastColumnHasLabel else { return }
                    result.removeLast()
                }
                lastColumn = column; lastColumnHasLabel = labeled
                result.append(Tick(time: time, primary: primary, label: labels && labeled ? timeLabel(time) : ""))
            }
            for index in stride(from: first, through: last, by: strideBars) {
                let time = section.start + Double(index) * bar
                guard time < section.end else { continue }
                let barClearance = index == 0 ? boundaryClearance :
                    min(Double(hierarchyStep(index)) * bar, boundaryEnd - time)
                append(time, primary: true, clearance: barClearance)
                if minor < bar {
                    for offset in stride(from: minor, to: min(bar, section.end - time) - 1e-9, by: minor) {
                        let subdivision = max(1, Int((offset / base).rounded()))
                        let clearance = min(Double(hierarchyStep(subdivision)) * base,
                                            bar - offset, boundaryEnd - time - offset)
                        append(time + offset, primary: false, clearance: clearance)
                    }
                }
            }
        }
        result.removeAll { $0.time < max(0, start) || $0.time > end }
        return result
    }
    private static func timeLabel(_ time: Double) -> String {
        let milliseconds = Int((time * 1000).rounded())
        let whole = milliseconds / 1000
        let base = String(format: "%02d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
        return milliseconds % 1000 == 0 ? base : base + String(format: ".%03d", milliseconds % 1000)
    }
}
