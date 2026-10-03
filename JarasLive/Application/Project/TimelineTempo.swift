import Foundation

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
        Int(pow(2, max(0, ceil(log2(minimumGridSpacing / max(0.001, bar * pixelsPerSecond))))))
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
        let width = bar * pixelsPerSecond
        if width >= minimumGridSpacing * 4 {
            let step = bar / Double(beats) * Double(unit) / Double(divisions ?? unit)
            return step * pow(2, max(0, ceil(log2(minimumGridSpacing / max(0.001, step * pixelsPerSecond)))))
        }
        return bar * Double(barStride(bar: bar, pixelsPerSecond: pixelsPerSecond))
    }
    public static func snap(_ time: Double, bar: Double, beats: Int, pixelsPerSecond: Double, divisions: Int? = nil, unit: Int = 4) -> Double {
        let step = gridStep(bar: bar, beats: beats, pixelsPerSecond: pixelsPerSecond, divisions: divisions, unit: unit)
        guard step > 0 else { return max(0, time) }
        return max(0, (time / step).rounded() * step)
    }
    public static func snap<Anchors: Sequence>(_ time: Double, bar: Double, beats: Int,
                                               pixelsPerSecond: Double, anchors: Anchors,
                                               additionalAnchors: Anchors? = nil,
                                               cursor: Double? = nil, tolerancePixels: Double = 8, gridTolerancePixels: Double? = nil, divisions: Int? = nil, unit: Int = 4, enabled: Bool = true) -> Double where Anchors.Element == Double {
        guard time.isFinite, pixelsPerSecond.isFinite, pixelsPerSecond > 0 else { return 0 }
        let position = max(0, time)
        guard enabled else { return position }
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
        if let nearest { return nearest }
        let grid = snap(position, bar: bar, beats: beats, pixelsPerSecond: pixelsPerSecond, divisions: divisions, unit: unit)
        if let gridTolerancePixels, abs(grid - position) * pixelsPerSecond > max(0, gridTolerancePixels) { return position }
        return grid
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

public extension Song {
    mutating func followTempo(_ value: Double) {
        guard projectTime.timebase == .relative else { bpm = value; return }
        guard value != bpm else { return }
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
    mutating func configureTiming(bpm value: Double, beats: Int, unit: Int, settings: ProjectTimeSettings) {
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
    public var barSeconds: Double { 60 / bpm * Double(beats) * 4 / Double(unit) }
}
public extension Song {
    func canDragMarker(_ marker: TimelineMarker) -> Bool {
        guard marker.sourceRegionID == nil, marker.unifiedRegionID == nil else { return false }
        return !marker.isTempo || !parts.contains { marker.position >= $0.startTime && marker.position < $0.endTime }
    }
    func markerDragPosition(_ marker: TimelineMarker, to value: Double, pixelsPerSecond: Double, free: Bool) -> Double {
        guard canDragMarker(marker), value.isFinite else { return marker.position }
        let target = max(0, value)
        if !marker.isTempo { return free ? target : TimelineTempo.snap(target, song: self, pixelsPerSecond: pixelsPerSecond) }
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
    var tempoMarkersAffectAudio: Bool {
        (markers ?? []).contains { $0.isTempo && ($0.tempoTimebase ?? .global).resolved(project: projectTime.timebase) == .relative }
    }
    func tempoSections(until end: Double) -> [TimelineTempoSection] {
        var result: [TimelineTempoSection] = []
        var start = 0.0, tempo = bpm, beats = meterBeats, unit = meterUnit
        var timebase = projectTime.timebase
        var referenceBPM: Double? = nil
        for marker in (markers ?? []).filter(\.isTempo).sorted(by: { $0.position == $1.position ? $0.id.uuidString < $1.id.uuidString : $0.position < $1.position }) {
            guard marker.position <= end else { break }
            if marker.position > start { result.append(TimelineTempoSection(start: start, end: marker.position, bpm: tempo, beats: beats, unit: unit, timebase: timebase, referenceBPM: referenceBPM)) }
            start = marker.position; tempo = marker.tempoBPM!; beats = marker.tempoBeats ?? 4; unit = marker.tempoUnit ?? 4
            timebase = (marker.tempoTimebase ?? .global).resolved(project: projectTime.timebase)
            referenceBPM = marker.tempoReferenceBPM
        }
        if end > start { result.append(TimelineTempoSection(start: start, end: end, bpm: tempo, beats: beats, unit: unit, timebase: timebase, referenceBPM: referenceBPM)) }
        return result
    }
    func tempoSection(at position: Double) -> TimelineTempoSection {
        tempoSections(until: max(duration, position + 1)).last { $0.start <= position } ?? TimelineTempoSection(start: 0, end: duration, bpm: bpm, beats: meterBeats, unit: meterUnit, timebase: projectTime.timebase)
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
        return min(end, parts.filter { !folders.contains($0.id) && $0.startTime > owner.startTime }.map(\.startTime).min() ?? end)
    }
    func audioTempoSections(owner: Part?, until end: Double, sections: [TimelineTempoSection]? = nil) -> [TimelineTempoSection] {
        let all = sections ?? tempoSections(until: end)
        guard let owner else { return all }
        let limit = tempoOwnerLimit(owner)
        let owned = all.filter { $0.start >= owner.startTime && $0.start < limit }
        var result: [TimelineTempoSection] = []
        var start = 0.0
        var current = TimelineTempoSection(start: 0, end: end, bpm: bpm, beats: meterBeats, unit: meterUnit, timebase: .free)
        for section in owned where section.start < end {
            if section.start > start {
                result.append(TimelineTempoSection(start: start, end: section.start, bpm: current.bpm, beats: current.beats, unit: current.unit, timebase: current.timebase, referenceBPM: current.referenceBPM))
            }
            start = section.start; current = section
        }
        if start < end { result.append(TimelineTempoSection(start: start, end: end, bpm: current.bpm, beats: current.beats, unit: current.unit, timebase: current.timebase, referenceBPM: current.referenceBPM)) }
        return result
    }
    /// Temporary playback fragments preserve item edits and source continuity.
    /// They do not split project items or create additional media files.
    func tempoAudioSegments(_ clip: AudioClip, sections: [TimelineTempoSection]? = nil) -> [AudioClip] {
        // Printed performances already contain their tempo changes.
        guard clip.frozenMIDI != true, clip.renderedTiming != true else { return [clip] }
        guard tempoMarkersAffectAudio else { return [clip] }
        let end = clip.startTime + clip.duration
        var source = clip.sourceOffset, result: [AudioClip] = []
        for section in audioTempoSections(owner: tempoOwner(at: clip.startTime), until: end, sections: sections) where section.end > clip.startTime && section.start < end {
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
            segment.playbackRate = section.timebase == .relative ? clip.audioRate * section.bpm / (section.referenceBPM ?? bpm) : clip.audioRate
            segment.sourceOffset = source
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
    static func snap(_ time: Double, song: Song, pixelsPerSecond: Double, regionEnds: Bool = false, cursor: Double? = nil, enabled: Bool = true, gridTolerancePixels: Double? = nil) -> Double {
        guard time.isFinite, pixelsPerSecond.isFinite, pixelsPerSecond > 0 else { return 0 }
        let section = song.tempoSection(at: max(0, time))
        let anchors = song.parts.lazy.map { $0.startTime - section.start }
        let ends = regionEnds ? song.parts.lazy.map { $0.endTime - section.start } : nil
        let offset = snap(time - section.start, bar: section.barSeconds, beats: section.beats, pixelsPerSecond: pixelsPerSecond,
            anchors: anchors, additionalAnchors: ends, cursor: cursor.map { $0 - section.start }, tolerancePixels: gridTolerancePixels ?? 8, gridTolerancePixels: gridTolerancePixels, divisions: song.projectTime.divisions, unit: section.unit, enabled: enabled)
        return min(section.end, section.start + offset)
    }
}

extension Song {
    /// An explicit initial section keeps the empty lead-in visible in the tempo lane.
    var initialTempoMarkerIfNeeded: TimelineMarker? {
        guard let first = markers?.filter(\.isTempo).map(\.position).min(), first > 0 else { return nil }
        return TimelineMarker(id: UUID(), name: "TEMPO", position: 0, color: 0x999999,
            tempoBPM: 120, tempoBeats: 4, tempoUnit: 4, tempoTimebase: .global, tempoReferenceBPM: 120)
    }
    mutating func ensureInitialTempoMarker() {
        if let initial = initialTempoMarkerIfNeeded { markers!.insert(initial, at: 0) }
    }
}

/// Maps a tempo edit without consuming or discarding source audio. Empty gaps
/// remain seconds; occupied song/clip intervals retain their musical duration.
struct TempoEditMap {
    private struct Span { let start: Double; let end: Double; let output: Double; let scale: Double }
    private var spans: [Span] = []
    private var clipDurations: [UUID: Double] = [:]
    private var regionDurations: [UUID: Double] = [:]
    var changesTime: Bool { spans.contains { abs($0.scale - 1) > 1e-12 } }
    init(before: Song, after: Song) {
        let folderIDs = Set(before.parts.compactMap(\.parentRegionID))
        var occupied = before.parts.filter { !folderIDs.contains($0.id) }.map { ($0.startTime, $0.endTime) }
        occupied += before.tracks.filter { $0.kind == .standard }.flatMap { track in
            track.clips.filter { ($0.audioFile != nil || track.audioFile != nil) && before.tempoOwner(at: $0.startTime) == nil }.map { ($0.startTime, $0.startTime + $0.duration) }
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
        func rate(_ song: Song, _ time: Double) -> Double {
            guard let marker = song.activeTempoMarker(at: time),
                  (marker.tempoTimebase ?? .global).resolved(project: song.projectTime.timebase) == .relative,
                  let bpm = marker.tempoBPM, bpm.isFinite, bpm > 0 else { return 1 }
            return bpm / (marker.tempoReferenceBPM ?? song.bpm)
        }
        var output = 0.0
        for (start, end) in zip(points, points.dropFirst()) {
            let middle = start + (end - start) / 2
            let filled = occupied.contains { $0.0 <= middle && middle < $0.1 }
            let scale = filled ? rate(before, middle) / rate(after, middle) : 1
            spans.append(Span(start: start, end: end, output: output, scale: scale))
            output += (end - start) * scale
        }
        func resizedDuration(start: Double, end: Double, owner: Part) -> Double {
            let old = before.audioTempoSections(owner: owner, until: end)
            let nextOwner = after.parts.first { $0.id == owner.id } ?? owner
            let new = after.audioTempoSections(owner: nextOwner, until: end)
            let edges = Array(Set([start, end] + (old + new).flatMap { [$0.start, $0.end] }.filter { $0 > start && $0 < end })).sorted()
            func speed(_ sections: [TimelineTempoSection], _ time: Double, _ song: Song) -> Double {
                guard let section = sections.last(where: { $0.start <= time }), section.timebase == .relative else { return 1 }
                return section.bpm / (section.referenceBPM ?? song.bpm)
            }
            return zip(edges, edges.dropFirst()).reduce(0) { total, edge in
                let middle = edge.0 + (edge.1 - edge.0) / 2
                return total + (edge.1 - edge.0) * speed(old, middle, before) / speed(new, middle, after)
            }
        }
        let folders = Set(before.parts.compactMap(\.parentRegionID))
        for part in before.parts where !folders.contains(part.id) {
            regionDurations[part.id] = resizedDuration(start: part.startTime, end: part.endTime, owner: part)
        }
        for track in before.tracks where track.kind == .standard {
            for clip in track.clips {
                if let owner = before.tempoOwner(at: clip.startTime) {
                    clipDurations[clip.id] = resizedDuration(start: clip.startTime, end: clip.startTime + clip.duration, owner: owner)
                }
            }
        }
    }
    func position(_ time: Double) -> Double {
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
            for item in song.tracks[track].clips.indices {
                let clip = song.tracks[track].clips[item]
                let start = position(clip.startTime), end = position(clip.startTime + clip.duration)
                song.tracks[track].clips[item].startTime = start
                song.tracks[track].clips[item].duration = clipDurations[clip.id] ?? (end - start)
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
        if song.markers != nil { for i in song.markers!.indices { song.markers![i].position = position(song.markers![i].position) } }
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
            ?? labelSpacing(through: sections.map(\.end).max() ?? end, pixelsPerSecond: scale)
        let labelSeconds = spacing / scale
        var result: [Tick] = []
        var previousLabel = -Double.infinity
        for section in sections where section.start <= end {
            if !labels && section.end < start { continue }
            let bar = section.barSeconds
            guard bar.isFinite, bar > 0, section.start.isFinite, section.end.isFinite,
                  section.end > section.start else { continue }
            let strideBars = TimelineTempo.barStride(bar: bar, pixelsPerSecond: scale)
            let first = max(0, Int(floor((start - section.start) / bar)) / strideBars * strideBars)
            let last = max(first, Int(ceil((min(section.end, end) - section.start) / bar)))
            let distant = bar * scale < TimelineTempo.minimumGridSpacing * 4
            let minor = distant ? bar * Double(strideBars) / 2 :
                TimelineTempo.gridStep(bar: bar, beats: section.beats, pixelsPerSecond: scale,
                                       divisions: divisions == 0 ? 4 : divisions, unit: section.unit)
            guard minor > 0, minor.isFinite else { continue }
            let labelBars = max(strideBars, Int(pow(2, max(0, ceil(log2(spacing / (bar * scale)))))))
            let labelMinor = max(1, Int(ceil(spacing / (minor * scale))))
            let firstAllowedLabel = previousLabel + labelSeconds
            // Account for earlier sections without scanning their offscreen bars.
            // Candidates within a section already have the required separation;
            // only its first candidates can conflict with the preceding section.
            if labels {
                let lastBar = max(0, Int(ceil((section.end - section.start) / bar)) - 1)
                var lastCandidate = section.start + Double(lastBar / labelBars * labelBars) * bar
                if !distant {
                    let labelStep = minor * Double(labelMinor)
                    for index in stride(from: lastBar, through: max(0, lastBar - 1), by: -1) {
                        let origin = section.start + Double(index) * bar
                        let available = min(bar - labelSeconds, (section.end - origin).nextDown)
                        if available >= labelStep {
                            lastCandidate = max(lastCandidate, origin + floor(available / labelStep) * labelStep)
                        }
                    }
                }
                if lastCandidate >= firstAllowedLabel { previousLabel = lastCandidate }
            }
            guard section.end >= start else { continue }
            func append(_ time: Double, primary: Bool, labeled: Bool) {
                guard time >= max(0, start), time <= end, time < section.end else { return }
                result.append(Tick(time: time, primary: primary,
                                   label: labels && labeled && time >= firstAllowedLabel ? timeLabel(time) : ""))
            }
            for index in stride(from: first, through: last, by: strideBars) {
                let time = section.start + Double(index) * bar
                guard time < section.end else { continue }
                append(time, primary: true, labeled: index % labelBars == 0)
                if distant {
                    append(time + minor, primary: false, labeled: false)
                } else {
                    var subdivision = 1
                    for offset in stride(from: minor, to: min(bar, section.end - time) - 1e-9, by: minor) {
                        append(time + offset, primary: false,
                               labeled: subdivision % labelMinor == 0 && (bar - offset) * scale >= spacing)
                        subdivision += 1
                    }
                }
            }
        }
        return result
    }
    private static func timeLabel(_ time: Double) -> String {
        let milliseconds = Int((time * 1000).rounded())
        let whole = milliseconds / 1000
        let base = String(format: "%02d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
        return milliseconds % 1000 == 0 ? base : base + String(format: ".%03d", milliseconds % 1000)
    }
}
