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
                    $0.id == itemID || $0.regionOwnerID == part.id || ($0.startTime <= part.startTime + 0.000001 && $0.startTime + $0.duration >= part.endTime - 0.000001)
                }
                guard !exists else { continue }
                songs[song].tracks[track].clips.append(AudioClip(id: itemID, name: "Click · " + part.name,
                    startTime: part.startTime, duration: part.endTime - part.startTime, regionOwnerID: part.id))
                added += 1
            }
            if added > 0 { songs[song].tracks[track].clips.sort { $0.startTime < $1.startTime } }
            return added
        }
        return 0
    }
}

public extension Song {
    /// Generated click fragments retain their original region when trimmed or split.
    func clickRegion(for clip: AudioClip) -> Part? {
        if let owner = clip.regionOwnerID, let part = parts.first(where: { $0.id == owner }) { return part }
        if let part = parts.first(where: { Project.clickItemID($0.id) == clip.id }) { return part }
        return parts.filter { $0.parentRegionID == nil && clip.startTime >= $0.startTime - 1e-6 &&
            clip.startTime + clip.duration <= $0.endTime + 1e-6 }.min { $0.endTime - $0.startTime < $1.endTime - $1.startTime }
    }
    func resizedClick(_ clip: AudioClip, start: Double, end: Double) -> AudioClip? {
        guard start.isFinite, end.isFinite, let region = clickRegion(for: clip) else { return nil }
        let lower = max(region.startTime, start), upper = min(region.endTime, end)
        guard upper - lower >= 0.01 - 1e-9 else { return nil }
        var result = clip
        result.startTime = lower; result.duration = upper - lower; result.regionOwnerID = region.id
        return result
    }
}

public struct ClickTrackSection: Equatable, Sendable {
    public let start: Double, end: Double, origin: Double, bpm: Double
    public let beats: Int, unit: Int
}
public enum ClickTrackProgram {
    public static func visibleBeats(sections: [TimelineTempoSection], start: Double, end: Double,
                                    visibleStart: Double, visibleEnd: Double, pixelsPerSecond: Double, doubled: Bool = false) -> [Double] {
        guard pixelsPerSecond.isFinite, pixelsPerSecond > 0 else { return [] }
        var result: [Double] = []
        for section in sections {
            let first = max(start, visibleStart, section.start), last = min(end, visibleEnd, section.end)
            guard first < last else { continue }
            let beat = 60 / section.bpm * 4 / Double(section.unit) / (doubled ? 2 : 1)
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
        // Partition overlaps once, choosing the densest active item without summing clicks.
        let edges = Array(Set(items.flatMap { [$0.startTime, $0.startTime + $0.duration] })).sorted()
        var spans: [(Double, Double, Int)] = []
        for (start, end) in zip(edges, edges.dropFirst()) where end > start {
            let active = items.filter { $0.startTime < end && $0.startTime + $0.duration > start }
            guard !active.isEmpty else { continue }
            let rate = active.contains { $0.clickDouble == true } ? 2 : 1
            if let previous = spans.last, previous.1 == start, previous.2 == rate {
                spans[spans.count - 1].1 = end
            } else { spans.append((start, end, rate)) }
        }
        let tempo = song.tempoSections(until: max(song.duration, spans.last?.1 ?? 0))
        var result: [ClickTrackSection] = []
        for span in spans {
            for section in tempo where section.end > span.0 && section.start < span.1 {
                result.append(ClickTrackSection(start: max(span.0, section.start), end: min(span.1, section.end),
                    origin: section.start, bpm: section.bpm * Double(span.2), beats: section.beats * span.2, unit: section.unit))
            }
        }
        return result
    }
}

public extension ClickTrackProgram {
    /// Only membership changes rebuild the immutable generator program. The
    /// advancing transport position must not allocate a new program each tick.
    struct PlaybackContext: Equatable {
        public let scope: PlaybackScope
        public let exclusiveRegion: UUID?
        public let suspendsOwnedItems: Bool
    }
    static func playbackContext(song: Song, track: Track, transport: TransportState, head: Int,
                                selectedTracks: Set<UUID>) -> PlaybackContext {
        let exclusive = head != 2 && selectedTracks.contains(track.id)
        return PlaybackContext(scope: song.playbackScope(transport, head: head),
            exclusiveRegion: exclusive ? (head == 0 ? transport.exclusivePlaybackRegionId : transport.subExclusivePlaybackRegionId) : nil,
            suspendsOwnedItems: exclusive && head == 0 && transport.subPlay.playing && transport.subExclusivePlaybackRegionId != nil)
    }
    /// Match audio-item membership separately for the primary and Subplay
    /// generators, including the incoming region retained after promotion.
    static func sections(song: Song, track: Track, transport: TransportState, head: Int,
                         selectedTracks: Set<UUID>) -> [ClickTrackSection] {
        let scope = song.playbackScope(transport, head: head)
        var filtered = track
        filtered.clips = track.clips.filter { clip in
            var owned = clip
            if owned.regionOwnerID == nil { owned.regionOwnerID = song.clickRegion(for: clip)?.id }
            return scope.allows(song.playbackItemStart(owned)) &&
                song.allowsExclusiveSubplay(transport, head: head, track: track.id,
                    owner: owned.regionOwnerID, selectedTracks: selectedTracks)
        }
        return sections(song: song, track: filtered)
    }
}
