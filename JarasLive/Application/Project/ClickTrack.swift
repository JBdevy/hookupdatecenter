import Foundation

public extension Project {
    static func clickItemID(_ region: UUID) -> UUID {
        var text = region.uuidString
        let first = Int(String(text.removeFirst()), radix: 16)!
        return UUID(uuidString: String(first ^ 4, radix: 16) + text)!
    }
    /// Insert is explicit and idempotent. Existing items, including user trims,
    /// remain untouched; child sections share the outer song's click item.
    @discardableResult mutating func insertClickItems(track id: UUID) -> Int {
        for song in songs.indices {
            guard let track = songs[song].tracks.firstIndex(where: { $0.id == id && $0.kind == .click }) else { continue }
            var added = 0
            for part in songs[song].parts where part.parentRegionID == nil && part.endTime > part.startTime {
                let itemID = Self.clickItemID(part.id)
                let exists = songs[song].tracks[track].clips.contains {
                    $0.id == itemID || ($0.startTime <= part.startTime + 0.000001 && $0.startTime + $0.duration >= part.endTime - 0.000001)
                }
                guard !exists else { continue }
                songs[song].tracks[track].clips.append(AudioClip(id: itemID, name: "Click · " + part.name,
                    startTime: part.startTime, duration: part.endTime - part.startTime))
                added += 1
            }
            if added > 0 { songs[song].tracks[track].clips.sort { $0.startTime < $1.startTime } }
            return added
        }
        return 0
    }
}

public struct ClickTrackSection: Equatable, Sendable {
    public let start: Double, end: Double, origin: Double, bpm: Double
    public let beats: Int, unit: Int
}
public enum ClickTrackProgram {
    public static func visibleBeats(sections: [TimelineTempoSection], start: Double, end: Double,
                                    visibleStart: Double, visibleEnd: Double, pixelsPerSecond: Double) -> [Double] {
        guard pixelsPerSecond.isFinite, pixelsPerSecond > 0 else { return [] }
        var result: [Double] = []
        for section in sections {
            let first = max(start, visibleStart, section.start), last = min(end, visibleEnd, section.end)
            guard first < last else { continue }
            let beat = 60 / section.bpm * 4 / Double(section.unit)
            let step = max(1, ceil(1 / (beat * pixelsPerSecond)))
            var index = max(0, ceil((first - section.start) / beat - 1e-9))
            index = ceil(index / step) * step
            while section.start + index * beat < last - 1e-9 {
                result.append(section.start + index * beat); index += step
            }
        }
        return result
    }
    /// Merge overlapping items so an overlap never doubles the click amplitude.
    /// Tempo origin stays on its marker, even if an item starts between beats.
    public static func sections(song: Song, track: Track) -> [ClickTrackSection] {
        let items = track.clips.filter { $0.muted != true && $0.audioFile == nil }.sorted { $0.startTime < $1.startTime }
        var spans: [(Double, Double)] = []
        for item in items {
            let end = item.startTime + item.duration
            if let previous = spans.last, previous.1 >= item.startTime {
                spans[spans.count - 1].1 = max(previous.1, end)
            } else { spans.append((item.startTime, end)) }
        }
        let tempo = song.tempoSections(until: max(song.duration, spans.last?.1 ?? 0))
        var result: [ClickTrackSection] = []
        for span in spans {
            for section in tempo where section.end > span.0 && section.start < span.1 {
                result.append(ClickTrackSection(start: max(span.0, section.start), end: min(span.1, section.end),
                    origin: section.start, bpm: section.bpm, beats: section.beats, unit: section.unit))
            }
        }
        return result
    }
}
