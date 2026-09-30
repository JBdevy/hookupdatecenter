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
    public var timebase: ProjectTimebase = .free
    public var affectsMIDIItems = false
    public var affectsAutomationLength = true
    public init() {}
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
                                               cursor: Double? = nil, tolerancePixels: Double = 8, divisions: Int? = nil, unit: Int = 4, enabled: Bool = true) -> Double where Anchors.Element == Double {
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
        return nearest ?? snap(position, bar: bar, beats: beats, pixelsPerSecond: pixelsPerSecond, divisions: divisions, unit: unit)
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
    public var barSeconds: Double { 60 / bpm * Double(beats) * 4 / Double(unit) }
}
public extension Song {
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
        for marker in (markers ?? []).filter(\.isTempo).sorted(by: { $0.position == $1.position ? $0.id.uuidString < $1.id.uuidString : $0.position < $1.position }) {
            guard marker.position <= end else { break }
            if marker.position > start { result.append(TimelineTempoSection(start: start, end: marker.position, bpm: tempo, beats: beats, unit: unit, timebase: timebase)) }
            start = marker.position; tempo = marker.tempoBPM!; beats = marker.tempoBeats ?? 4; unit = marker.tempoUnit ?? 4
            timebase = (marker.tempoTimebase ?? .global).resolved(project: projectTime.timebase)
        }
        if end > start { result.append(TimelineTempoSection(start: start, end: end, bpm: tempo, beats: beats, unit: unit, timebase: timebase)) }
        return result
    }
    func tempoSection(at position: Double) -> TimelineTempoSection {
        tempoSections(until: max(duration, position + 1)).last { $0.start <= position } ?? TimelineTempoSection(start: 0, end: duration, bpm: bpm, beats: meterBeats, unit: meterUnit, timebase: projectTime.timebase)
    }
    /// Temporary playback fragments preserve item edits and source continuity.
    /// They do not split project items or create additional media files.
    func tempoAudioSegments(_ clip: AudioClip, sections: [TimelineTempoSection]? = nil) -> [AudioClip] {
        guard tempoMarkersAffectAudio else { return [clip] }
        let end = clip.startTime + clip.duration
        var source = clip.sourceOffset, result: [AudioClip] = []
        for section in sections ?? tempoSections(until: end) where section.end > clip.startTime && section.start < end {
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
            segment.startTime = start; segment.duration = finish - start
            segment.playbackRate = section.timebase == .relative ? clip.audioRate * section.bpm / bpm : clip.audioRate
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
    static func snap(_ time: Double, song: Song, pixelsPerSecond: Double, regionEnds: Bool = false, cursor: Double? = nil, enabled: Bool = true) -> Double {
        guard time.isFinite, pixelsPerSecond.isFinite, pixelsPerSecond > 0 else { return 0 }
        let section = song.tempoSection(at: max(0, time))
        let anchors = song.parts.lazy.map { $0.startTime - section.start }
        let ends = regionEnds ? song.parts.lazy.map { $0.endTime - section.start } : nil
        let offset = snap(time - section.start, bar: section.barSeconds, beats: section.beats, pixelsPerSecond: pixelsPerSecond,
            anchors: anchors, additionalAnchors: ends, cursor: cursor.map { $0 - section.start }, divisions: song.projectTime.divisions, unit: section.unit, enabled: enabled)
        return min(section.end, section.start + offset)
    }
}
