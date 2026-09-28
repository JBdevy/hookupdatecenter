import Foundation

/// Item values share immutable waveform storage and reference the original media.
/// A pending move does not alter the arrangement until the whole paste succeeds.
public struct GridItemClipboard: Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var track: UUID
        public var clip: AudioClip
    }
    public let project: UUID
    public let song: UUID
    public var moving: Bool
    public let entries: [Entry]
    public init?(project: Project, song: UUID, selected: Set<UUID>, moving: Bool = false) {
        guard let source = project.songs.first(where: { $0.id == song }) else { return nil }
        let entries = source.tracks.filter { $0.kind != .timecode }.flatMap { track in
            track.clips.filter { selected.contains($0.id) }.map { Entry(track: track.id, clip: $0) }
        }
        guard !entries.isEmpty else { return nil }
        self.project = project.id; self.song = song; self.moving = moving; self.entries = entries
    }
    public func items(in project: Project, at position: Double) throws -> [Entry] {
        guard project.id == self.project, position.isFinite, position >= 0,
              let source = project.songs.first(where: { $0.id == song }) else { throw ProjectError.invalid("The copied items belong to another project") }
        var values = entries
        for index in values.indices {
            guard let track = source.tracks.first(where: { $0.id == values[index].track }), track.kind != .timecode else {
                throw ProjectError.invalid("The destination track no longer exists")
            }
            if moving {
                guard let clip = track.clips.first(where: { $0.id == values[index].clip.id }) else { throw ProjectError.invalid("An item to move no longer exists") }
                values[index].clip = clip
            }
        }
        let start = values.map { $0.clip.startTime }.min()!
        for index in values.indices {
            values[index].clip.startTime = position + (values[index].clip.startTime - start)
            if !moving { values[index].clip.id = UUID() }
        }
        return values
    }
}

public extension Project {
    mutating func pasteItems(_ entries: [GridItemClipboard.Entry], song: UUID, moving: Bool) throws {
        guard !entries.isEmpty, let index = songs.firstIndex(where: { $0.id == song }),
              Set(entries.map { $0.clip.id }).count == entries.count else { throw ProjectError.invalid("Invalid item paste") }
        var candidate = self
        for entry in entries {
            guard let track = candidate.songs[index].tracks.firstIndex(where: { $0.id == entry.track }),
                  candidate.songs[index].tracks[track].kind != .timecode else { throw ProjectError.invalid("Invalid destination track") }
            if moving {
                guard let item = candidate.songs[index].tracks[track].clips.firstIndex(where: { $0.id == entry.clip.id }) else { throw ProjectError.invalid("An item to move no longer exists") }
                candidate.songs[index].tracks[track].clips.remove(at: item)
            }
        }
        for entry in entries {
            let track = candidate.songs[index].tracks.firstIndex { $0.id == entry.track }!
            candidate.songs[index].tracks[track].clips.append(entry.clip)
            candidate.songs[index].duration = max(candidate.songs[index].duration, entry.clip.startTime + entry.clip.duration)
        }
        try candidate.validate()
        self = candidate
    }
}
