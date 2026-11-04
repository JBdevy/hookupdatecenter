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
    private let sourceRows: [UUID: Int]
    private let sourceTrackTemplates: [Track]
    public init?(project: Project, song: UUID, selected: Set<UUID>, moving: Bool = false) {
        guard let source = project.songs.first(where: { $0.id == song }) else { return nil }
        let entries = source.tracks.filter { $0.kind != .timecode }.flatMap { track in
            track.clips.filter { selected.contains($0.id) && (track.kind != .click || $0.isProjectionMedia) }.map { Entry(track: track.id, clip: $0) }
        }
        guard !entries.isEmpty else { return nil }
        self.project = project.id; self.song = song; self.moving = moving; self.entries = entries
        sourceRows = Dictionary(uniqueKeysWithValues: source.tracks.enumerated().map { ($0.element.id, $0.offset) })
        sourceTrackTemplates = source.tracks.map {
            Track(id: $0.id, name: $0.name, role: $0.kind == .standard ? $0.role : .other, color: $0.color)
        }
    }
    public struct CopyPlan: Sendable {
        public var entries: [Entry]
        public var newTracks: [Track]
    }
    /// A new project has no tracks yet. Add only missing destination rows as
    /// part of the paste transaction, keeping source row gaps and item offsets.
    public func copyPlan(in destination: Song, at position: Double, selectedTracks: Set<UUID>) throws -> CopyPlan {
        guard !moving, let first = entries.compactMap({ sourceRows[$0.track] }).min(),
              let last = entries.compactMap({ sourceRows[$0.track] }).max() else {
            throw ProjectError.invalid("Select a destination track before pasting.")
        }
        let target = destination.tracks.firstIndex { selectedTracks.contains($0.id) }
            ?? destination.tracks.firstIndex { $0.kind == .standard } ?? destination.tracks.count
        var expanded = destination
        var newTracks: [Track] = []
        while expanded.tracks.count <= target + last - first {
            var track = sourceTrackTemplates[first + expanded.tracks.count - target]
            track.id = UUID()
            expanded.tracks.append(track); newTracks.append(track)
        }
        let targetID = expanded.tracks[target].id
        return try CopyPlan(entries: copiedItems(in: expanded, at: position, selectedTracks: [targetID]), newTracks: newTracks)
    }
    /// Cross-document copying uses the captured row order, never IDs from the
    /// destination document. Media is staged separately before committing.
    public func copiedItems(in destination: Song, at position: Double, selectedTracks: Set<UUID>) throws -> [Entry] {
        guard !moving, position.isFinite, position >= 0,
              let firstRow = entries.compactMap({ sourceRows[$0.track] }).min(),
              let target = destination.tracks.firstIndex(where: { selectedTracks.contains($0.id) })
                ?? destination.tracks.firstIndex(where: { $0.kind == .standard }),
              let firstTime = entries.map({ $0.clip.startTime }).min() else {
            throw ProjectError.invalid("Select a destination track before pasting.")
        }
        return try entries.map { entry in
            let row = target + (sourceRows[entry.track] ?? firstRow) - firstRow
            guard destination.tracks.indices.contains(row) else { throw ProjectError.invalid("Not enough destination tracks to paste these items.") }
            var clip = entry.clip
            clip.id = UUID(); clip.separatedStemTracks = nil; clip.regionOwnerID = nil
            clip.startTime = position + entry.clip.startTime - firstTime
            return Entry(track: destination.tracks[row].id, clip: clip)
        }
    }
    public func items(in project: Project, at position: Double, selectedTracks: Set<UUID> = []) throws -> [Entry] {
        guard project.id == self.project, position.isFinite, position >= 0,
              let source = project.songs.first(where: { $0.id == song }) else { throw ProjectError.invalid("The copied items belong to another project") }
        var values = entries
        // Resolve the destination in timeline order, never Set iteration order or
        // the last track clicked. Keep multi-track selections arranged together.
        let destination = source.tracks.firstIndex { selectedTracks.contains($0.id) }
        let firstSource = source.tracks.firstIndex { track in entries.contains { $0.track == track.id } }
        for index in values.indices {
            guard let sourceIndex = source.tracks.firstIndex(where: { $0.id == values[index].track }),
                  source.tracks[sourceIndex].kind != .timecode else {
                throw ProjectError.invalid("The destination track no longer exists")
            }
            let track = source.tracks[sourceIndex]
            guard track.kind != .click || values[index].clip.isProjectionMedia else { throw ProjectError.invalid("Invalid destination track") }
            if moving {
                guard let clip = track.clips.first(where: { $0.id == values[index].clip.id }) else { throw ProjectError.invalid("An item to move no longer exists") }
                values[index].clip = clip
            }
            guard track.kind != .click || values[index].clip.isProjectionMedia else { throw ProjectError.invalid("Invalid destination track") }
            if let destination, let firstSource {
                let target = destination + sourceIndex - firstSource
                guard source.tracks.indices.contains(target) else { throw ProjectError.invalid("Invalid destination track") }
                values[index].track = source.tracks[target].id
            }
        }
        let start = values.map { $0.clip.startTime }.min()!
        for index in values.indices {
            values[index].clip.startTime = position + (values[index].clip.startTime - start)
            if !moving { values[index].clip.id = UUID(); values[index].clip.separatedStemTracks = nil }
        }
        return values
    }
}

public extension Project {
    mutating func pasteItems(_ entries: [GridItemClipboard.Entry], song: UUID, moving: Bool, addingTracks: [Track] = []) throws {
        guard !entries.isEmpty, let index = songs.firstIndex(where: { $0.id == song }),
              Set(entries.map { $0.clip.id }).count == entries.count else { throw ProjectError.invalid("Invalid item paste") }
        var candidate = self
        candidate.songs[index].tracks.append(contentsOf: addingTracks)
        for entry in entries {
            guard let track = candidate.songs[index].tracks.firstIndex(where: { $0.id == entry.track }),
                  candidate.songs[index].tracks[track].kind != .timecode,
                  candidate.songs[index].tracks[track].kind != .click || entry.clip.isProjectionMedia else { throw ProjectError.invalid("Invalid destination track") }
            if moving {
                guard let origin = candidate.songs[index].tracks.firstIndex(where: { $0.clips.contains { $0.id == entry.clip.id } }),
                      let item = candidate.songs[index].tracks[origin].clips.firstIndex(where: { $0.id == entry.clip.id }) else { throw ProjectError.invalid("An item to move no longer exists") }
                guard candidate.songs[index].tracks[origin].kind != .timecode,
                      candidate.songs[index].tracks[origin].kind != .click || candidate.songs[index].tracks[origin].clips[item].isProjectionMedia else { throw ProjectError.invalid("Invalid destination track") }
                candidate.songs[index].tracks[origin].clips.remove(at: item)
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

/// A private directory per paste prevents filename collisions and makes failed
/// transfers removable without touching either project's existing media.
public struct GridItemMediaTransfer: Sendable {
    public var entries: [GridItemClipboard.Entry]
    public var directories: [URL] = []
    public func discard() { for directory in directories { try? FileManager.default.removeItem(at: directory) } }
    public static func stage(_ entries: [GridItemClipboard.Entry], from source: URL?, to destination: URL?) throws -> Self {
        var result = Self(entries: entries)
        let paths = Set(entries.compactMap { $0.clip.audioFile?.path }).union(entries.flatMap { $0.clip.fx?.samplePaths ?? [] })
        guard !paths.isEmpty else { return result }
        guard let source, let destination else { throw ProjectError.invalid("No project media directory") }
        let batch = "Clipboard-" + UUID().uuidString
        var mapping: [String: String] = [:]
        do {
            for (index, path) in paths.sorted().enumerated() {
                try Task.checkCancellation()
                let input = path.hasPrefix("/") ? URL(fileURLWithPath: path) : source.appendingPathComponent(path)
                let folder = (path.hasPrefix("Videos/") ? "Videos/" : "Stems/") + batch
                let relative = folder + "/\(index)-" + input.lastPathComponent
                let directory = destination.appendingPathComponent(folder, isDirectory: true)
                if !result.directories.contains(directory) {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    result.directories.append(directory)
                }
                try FileManager.default.copyItem(at: input, to: destination.appendingPathComponent(relative))
                mapping[path] = relative
            }
            for index in result.entries.indices {
                if let path = result.entries[index].clip.audioFile?.path { result.entries[index].clip.audioFile?.path = mapping[path]! }
                result.entries[index].clip.fx?.remapSamples(mapping)
            }
            return result
        } catch { result.discard(); throw error }
    }
}
